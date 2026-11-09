#include <metal_stdlib>
using namespace metal;
constant float3 lumaWeights=float3(0.2126,0.7152,0.0722);
float luminance(float3 c){return dot(c,lumaWeights);}
float3 decodeRGB(float3 c){return select(c/12.92,sign(c)*pow((abs(c)+0.055)/1.055,float3(2.4)),abs(c)>0.04045);}
float3 encodeRGB(float3 c){return select(c*12.92,sign(c)*(1.055*pow(abs(c),float3(1.0/2.4))-0.055),abs(c)>0.0031308);}
bool outside(uint2 id,texture2d<float,access::write> out){return id.x>=out.get_width()||id.y>=out.get_height();}
kernel void transfer(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float3 c=src.read(id).rgb;dst.write(float4(p[0]>0?encodeRGB(c):decodeRGB(c),1),id);
}
float3 sampleCube(float3 value,texture3d<float,access::read> lut,bool extrapolate) {
 float3 coord=(extrapolate ? value : clamp(value,0.0,1.0))*float(lut.get_width()-1);
 // Clamp indices BEFORE integer conversion, but retain out-of-range weights.
 // This continues the boundary cell's trilinear function on faces, edges and corners.
 uint3 lo,hi;float3 f;
 if(extrapolate) {
  lo=uint3(clamp(floor(coord),0.0f,float(lut.get_width()-2)));hi=lo+1;f=coord-float3(lo);
 } else {
  // Keep the original SDR endpoint sampling and rounding unchanged.
  lo=uint3(floor(coord));hi=min(lo+1,uint3(lut.get_width()-1));f=fract(coord);
 }
 float3 a=mix(lut.read(uint3(lo.x,lo.y,lo.z)).rgb,lut.read(uint3(hi.x,lo.y,lo.z)).rgb,f.x);
 float3 b=mix(lut.read(uint3(lo.x,hi.y,lo.z)).rgb,lut.read(uint3(hi.x,hi.y,lo.z)).rgb,f.x);
 float3 c=mix(lut.read(uint3(lo.x,lo.y,hi.z)).rgb,lut.read(uint3(hi.x,lo.y,hi.z)).rgb,f.x);
 float3 d=mix(lut.read(uint3(lo.x,hi.y,hi.z)).rgb,lut.read(uint3(hi.x,hi.y,hi.z)).rgb,f.x);
 return mix(mix(a,b,f.y),mix(c,d,f.y),f.z);
}
kernel void lutMap(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture3d<float,access::read> lut[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;dst.write(float4(sampleCube(src.read(id).rgb,lut,false),1),id);
}
kernel void lutMapExtrapolated(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture3d<float,access::read> lut[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;dst.write(float4(sampleCube(src.read(id).rgb,lut,true),1),id);
}
int reflected(int v,int n){if(n<=1)return 0;int period=2*n-2;v=((v%period)+period)%period;return v<n?v:period-v;}
kernel void gaussian(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;
 float sigma=p[0];if(sigma<0.08){dst.write(src.read(id),id);return;}
 int radius=int(ceil(3*sigma));float4 sum=0;float denom=0;
 for(int i=-radius;i<=radius;i++){
  int2 xy=int2(id)+(p[1]>0?int2(0,i):int2(i,0));
  xy=p[2]>0?int2(reflected(xy.x,src.get_width()),reflected(xy.y,src.get_height())):clamp(xy,int2(0),int2(src.get_width()-1,src.get_height()-1));
  float w=exp(-float(i*i)/(2*sigma*sigma));sum+=w*src.read(uint2(xy));denom+=p[2]>0?w*w:w;
 }
 dst.write(sum/(p[2]>0?sqrt(denom):denom),id);
}
// Preview/still texture path: weights are invariant across pixels and prepared on the host.
kernel void gaussianPrepared(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],constant float* weights[[buffer(1)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;
 int radius=int(p[0]);float4 sum=0;
 for(int i=-radius;i<=radius;i++){
  int2 xy=int2(id)+(p[1]>0?int2(0,i):int2(i,0));
  xy=p[3]>0?int2(reflected(xy.x,src.get_width()),reflected(xy.y,src.get_height())):clamp(xy,int2(0),int2(src.get_width()-1,src.get_height()-1));
  sum+=weights[i+radius]*src.read(uint2(xy));
 }
 dst.write(sum/p[2],id);
}
kernel void detailCombine(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> fine[[texture(2)]],texture2d<float,access::read> mid[[texture(3)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float3 c=src.read(id).rgb;float y=luminance(c),f=luminance(fine.read(id).rgb),m=luminance(mid.read(id).rgb);float target=m+p[0]*(y-f)+p[1]*(f-m);dst.write(float4(c+(target-y),1),id);
}
kernel void sharpen(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> blur[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float3 c=src.read(id).rgb;float diff=luminance(c-blur.read(id).rgb);float gate=smoothstep(p[1],max(p[1]*2,1e-6),abs(diff));float change=clamp(diff*p[0]*gate,-p[2],p[2]);dst.write(float4(c+change,1),id);
}
kernel void vignette(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float2 size=float2(src.get_width(),src.get_height());float r=min(1.0,length(float2(id)+0.5-size*float2(p[3],p[4]))/(length(size)*0.5));float curve=pow(smoothstep(p[1],1.0,r),p[2]);dst.write(float4(src.read(id).rgb*exp2(-p[0]*curve),1),id);
}
kernel void highlights(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float3 c=src.read(id).rgb;float mask=smoothstep(p[0]-p[1],p[0]+p[1],luminance(c));dst.write(float4(c*mask,1),id);
}
kernel void glowCombine(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> hi[[texture(2)]],texture2d<float,access::read> near[[texture(3)]],texture2d<float,access::read> far[[texture(4)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float3 b=mix(near.read(id).rgb,far.read(id).rgb,p[1]);float3 c=p[2]>0?b:src.read(id).rgb+p[0]*(b-hi.read(id).rgb);dst.write(float4(c,1),id);
}
// Compute interpolation weights in full-frame pixel coordinates. Texture sampler
// rounding depends on the size of its bound texture, which changes between tiles.
float3 resizePixel(texture2d<float,access::read> source, float2 position, int2 origin) {
    int2 base = int2(floor(position)) - origin;
    int2 last = int2(source.get_width()-1, source.get_height()-1);
    uint2 lo = uint2(clamp(base, int2(0), last)), hi = uint2(clamp(base+1, int2(0), last));
    float2 f = fract(position);
    float3 a = mix(source.read(lo).rgb, source.read(uint2(hi.x,lo.y)).rgb, f.x);
    float3 b = mix(source.read(uint2(lo.x,hi.y)).rgb, source.read(hi).rgb, f.x);
    return mix(a,b,f.y);
}
float3 resizeSample(texture2d<float,access::read> source, uint2 pixel, float2 sourceSize,
                    float2 destinationSize, int2 sourceOrigin) {
    int steps = min(8,max(1,int(ceil(max(sourceSize.x/destinationSize.x,sourceSize.y/destinationSize.y)))));
    float3 sum = 0;
    for (int y=0; y<steps; ++y) for (int x=0; x<steps; ++x) {
        float2 position = ((float2(pixel)+(float2(x,y)+0.5)/steps)/destinationSize)*sourceSize - 0.5;
        sum += resizePixel(source,position,sourceOrigin);
    }
    return sum/float(steps*steps);
}
kernel void resizeLinear(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float3 value = resizeSample(src,id,float2(src.get_width(),src.get_height()),float2(dst.get_width(),dst.get_height()),int2(0));
    dst.write(float4(value,1),id);
}
uint hashValue(uint v){v^=v>>16;v*=0x7feb352d;v^=v>>15;v*=0x846ca68b;return v^(v>>16);}
float gaussianRandom(uint v){float a=(float(hashValue(v)>>8)+0.5)/16777216.0;float b=(float(hashValue(v^0x9e3779b9)>>8)+0.5)/16777216.0;return sqrt(-2*log(a))*cos(6.28318530718*b);}
kernel void randomField(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;uint v=hashValue(id.x+id.y*dst.get_width())^as_type<uint>(p[0]);dst.write(float4(gaussianRandom(v),gaussianRandom(v^0x68bc21eb),gaussianRandom(v^0x02e5be93),1),id);
}
// Unified analytic function / custom points. Layout matches PreparedResponseCurves.encode.
float responseValue(float x,constant float* p) {
 int family=int(p[0]);
 if(family>0) {
  float t=clamp((x-p[3])/(p[4]-p[3]),0.0f,1.0f),v=0;
  if(family==2)v=t;
  else if(family==3)v=pow(t,p[7]);
  else if(family==4) {
   float a=1/(1+exp(4*p[7]*p[8])),b=1/(1+exp(-4*p[7]*(1-p[8])));
   v=(1/(1+exp(-4*p[7]*(t-p[8])))-a)/(b-a);
  } else if(family==5){float q=clamp((t-p[8])/p[9]+0.5f,0.0f,1.0f);v=q*q*(3-2*q);}
  else if(family==6){float q=(t-p[8])/p[9];v=exp(-0.5f*q*q);}
  return clamp(mix(p[5],p[6],v),min(p[5],p[6]),max(p[5],p[6]));
 }
 int count=int(p[2]),i=0;
 x=clamp(x,p[10],p[10+3*(count-1)]);
 while(i<count-2 && x>p[10+3*(i+1)])i++;
 int a=10+3*i,b=a+3;float h=p[b]-p[a],t=(x-p[a])/h;
 if(p[1]==0)return mix(p[a+1],p[b+1],t);
 float t2=t*t,t3=t2*t;
 return clamp((2*t3-3*t2+1)*p[a+1]+(t3-2*t2+t)*h*p[a+2]+(-2*t3+3*t2)*p[b+1]+(t3-t2)*h*p[b+2],min(p[a+1],p[b+1]),max(p[a+1],p[b+1]));
}
float3 finishColor(float3 linear,texture2d<float,access::read> luma,texture2d<float,access::read> chroma,constant float* p,uint2 id) {
 float3 c=encodeRGB(linear);
 if(p[0]>0){float sigma=clamp(responseValue(luminance(c),p+4)*p[3],0.0f,0.1f);
 float dn=luma.read(id).r*sigma;float2 z=chroma.read(id).gb;float cb=z.x*sigma*p[1],cr=(p[2]*z.x+sqrt(1-p[2]*p[2])*z.y)*sigma*p[1];c+=float3(dn+1.5748*cr,dn-0.187324*cb-0.468124*cr,dn+1.8556*cb);
 }return c;
}
kernel void finish(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> luma[[texture(2)]],texture2d<float,access::read> chroma[[texture(3)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;dst.write(float4(clamp(finishColor(src.read(id).rgb,luma,chroma,p,id),0.0,1.0),1),id);
}
kernel void finishExtended(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> luma[[texture(2)]],texture2d<float,access::read> chroma[[texture(3)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;dst.write(float4(finishColor(src.read(id).rgb,luma,chroma,p,id),1),id);
}

// Display-only packing: values are already sRGB encoded by finish. No second transfer.
kernel void previewDisplay(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst))return;
    float4 value=src.read(id);
    dst.write(float4(clamp(value.rgb*clamp(value.a,0.0f,1.0f),0.0f,1.0f),1.0f),id);
}

kernel void toneResponse(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;float3 c=src.read(id).rgb;
 dst.write(float4(responseValue(c.r,p),responseValue(c.g,p),responseValue(c.b,p),1),id);
}
float extendedTone(float x,constant float* p) {
 // Preserve endpoint offsets with unit slope outside the authored SDR range.
 // Do not use this for noise/grain envelopes, whose weights intentionally stay bounded.
 return responseValue(x,p)+(x<0 ? x : max(0.0f,x-1.0f));
}
kernel void toneResponseExtended(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;float3 c=src.read(id).rgb;
 dst.write(float4(extendedTone(c.r,p),extendedTone(c.g,p),extendedTone(c.b,p),1),id);
}
kernel void softenCombine(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> blurred[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;dst.write(float4(mix(src.read(id).rgb,blurred.read(id).rgb,p[0]),1),id);
}
float3 halationResidual(float3 scales, float light) {
 float3 spread=float3(dot(scales,float3(.2,.3,.5)),dot(scales,float3(.3,.5,.2)),dot(scales,float3(.5,.4,.1)));
 return max(0.0f,spread-light);
}
kernel void halationCombine(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> sourceLight[[texture(2)]],texture2d<float,access::read> near[[texture(3)]],texture2d<float,access::read> mid[[texture(4)]],texture2d<float,access::read> far[[texture(5)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;
 float3 scales=float3(luminance(near.read(id).rgb),luminance(mid.read(id).rgb),luminance(far.read(id).rgb));
 float3 halo=halationResidual(scales,luminance(sourceLight.read(id).rgb));
 dst.write(float4(src.read(id).rgb+halo*p[0]*float3(p[1],p[2],p[3]),1),id);
}
// Integral of the centered cubic B-spline from -infinity to x.
float grainCDF(float x) {
    float t=max(0.0f,2.0f-abs(x)), u=max(0.0f,t-1.0f);
    float t2=t*t, u2=u*u, tail=(t2*t2-4*u2*u2)/24.0f;
    return x>0 ? 1-tail : tail;
}
// A random affine permutation of F_257 followed by cubing (also a permutation).
// A 16x16 block uses 256 distinct entries. Its exact sum is the negative of the
// missing entry plus its independent block mean. The mean cancels the negative
// covariance of sampling without replacement, preserving a white unit-variance lattice.
struct GrainBlock { uint a,b; float mean; };
GrainBlock grainBlock(uint key) {
    uint permutation=hashValue(key);
    float uniform=(float(hashValue(key^0x149b1aadu)>>8)+0.5f)/16777216.0f;
    return {1u+(permutation&255u),(permutation>>8)%257u,
            (uniform-0.5f)*(3.46410161514f*0.06237828616f)};
}
float grainEntry(GrainBlock block,uint index) {
    uint u=(block.a*index+block.b)%257u;
    return (float((u*u*u)%257u)-128.0f)*0.01345284717f;
}
float3 grainBlockValue(GrainBlock y,GrainBlock cb,GrainBlock cr,uint index,bool colored,bool complete) {
    float3 detail=float3(grainEntry(y,index),0,0);
    if (colored) detail.yz=float2(grainEntry(cb,index),grainEntry(cr,index));
    float3 mean=float3(y.mean,cb.mean,cr.mean);
    return complete ? 256*mean-detail : mean+detail;
}
float3 grainLayer(float2 pixel,float latticeWidth,float gain,uint seed,bool colored) {
    if (gain==0) return 0;
    float2 lo=pixel*latticeWidth;
    int2 base=int2(floor(lo)), first=base-1;
    float2 phase=fract(lo);
    int2 last=base+int2(ceil(phase+latticeWidth))+1;
    float3 sum=0;
    for (int by=first.y>>4;by<=(last.y>>4);++by) {
        for (int bx=first.x>>4;bx<=(last.x>>4);++bx) {
            uint key=hashValue(uint(bx))^hashValue(uint(by)+0x91e10da5u)^seed;
            GrainBlock y=grainBlock(key), cb=y, cr=y;
            if (colored) { cb=grainBlock(key^0x68bc21ebu); cr=grainBlock(key^0x02e5be93u); }
            int2 origin=int2(bx,by)*16;
            float2 start=float2(origin-base)-phase;
            if (all(start>=2) && all(start+17<=latticeWidth)) {
                sum+=grainBlockValue(y,cb,cr,256u,colored,true);
                continue;
            }
            for (int j=max(first.y,origin.y);j<=min(last.y,origin.y+15);++j) {
                float dy=phase.y-float(j-base.y);
                float wy=grainCDF(dy+latticeWidth)-grainCDF(dy);
                for (int i=max(first.x,origin.x);i<=min(last.x,origin.x+15);++i) {
                    float dx=phase.x-float(i-base.x);
                    float w=wy*(grainCDF(dx+latticeWidth)-grainCDF(dx));
                    uint index=uint((j-origin.y)*16+i-origin.x);
                    sum+=w*grainBlockValue(y,cb,cr,index,colored,false);
                }
            }
        }
    }
    return sum*(gain/(latticeWidth*latticeWidth));
}
float3 grainIntegral(float2 pixel, constant float* p, float factor) {
    uint seed=as_type<uint>(p[6]);
    return grainLayer(pixel,p[1]/factor,p[3],seed,p[5]>0)
          +grainLayer(pixel,p[2]/factor,p[4],seed^0xa341316cu,p[5]>0);
}
float4 applyGrain(float3 c, float3 v, constant float* p, bool extended=false) {
    float cb=v.y*p[5],cr=v.z*p[5];
    float amplitude=p[0]*responseValue(clamp(luminance(c),0.0f,1.0f),p+10);
    c+=amplitude*float3(v.x+1.5748f*cr,v.x-0.187324f*cb-0.468124f*cr,v.x+1.8556f*cb);
    return float4(extended ? c : clamp(c,0.0f,1.0f),1);
}
kernel void filmGrain(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 pixel=float2(id)+float2(p[7],p[8]);
    dst.write(applyGrain(src.read(id).rgb,grainIntegral(pixel,p,1),p),id);
}
kernel void filmGrainExtended(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 pixel=float2(id)+float2(p[7],p[8]);
    dst.write(applyGrain(src.read(id).rgb,grainIntegral(pixel,p,1),p,true),id);
}
kernel void grainSubpixels(texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float factor=p[9];
    float2 pixel=float2(id)+float2(p[7],p[8])*factor;
    dst.write(float4(grainIntegral(pixel,p,factor),1),id);
}
kernel void grainReduce(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],
                        texture2d<float,access::read> field[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    uint factor=uint(p[9]);
    float3 sum=0;
    for (uint y=0;y<factor;++y) for (uint x=0;x<factor;++x)
        sum+=field.read(id*factor+uint2(x,y)).rgb;
    dst.write(applyGrain(src.read(id).rgb,sum/float(factor*factor),p),id);
}
kernel void grainReduceExtended(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],
                        texture2d<float,access::read> field[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    uint factor=uint(p[9]);float3 sum=0;
    for (uint y=0;y<factor;++y) for (uint x=0;x<factor;++x) sum+=field.read(id*factor+uint2(x,y)).rgb;
    dst.write(applyGrain(src.read(id).rgb,sum/float(factor*factor),p,true),id);
}

// Decode -> exposure -> chromatic adaptation -> creative matrix -> encode.
// The host composes adaptation and creative matrix in that order. Keep extended signed values.
kernel void colorResponse(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;
 float3 c=decodeRGB(src.read(id).rgb)*p[0];
 float3 transformed=float3(dot(float3(p[1],p[2],p[3]),c),dot(float3(p[4],p[5],p[6]),c),dot(float3(p[7],p[8],p[9]),c));
 dst.write(float4(encodeRGB(transformed),1),id);
}

// Exact area-weighted reduction. Threshold is applied BEFORE averaging so subpixel
// bright sources contribute even when their average falls below the threshold.
float3 areaReduced(texture2d<float,access::read> src, uint2 cell, float2 sourceSize,
                   float2 gridSize, int2 origin, constant float* params) {
    float2 ratio = sourceSize/gridSize;
    float2 lower = float2(cell)*ratio, upper = min((float2(cell)+1)*ratio,sourceSize);
    uint2 end = uint2(ceil(upper));
    int2 last = int2(src.get_width()-1,src.get_height()-1);
    float3 sum = 0; float weight = 0;
    for(uint y=uint(lower.y); y<end.y; ++y) for(uint x=uint(lower.x); x<end.x; ++x) {
        float w = max(0.0f,min(upper.x,float(x+1))-max(lower.x,float(x)))
                * max(0.0f,min(upper.y,float(y+1))-max(lower.y,float(y)));
        float3 color = src.read(uint2(clamp(int2(x,y)-origin,int2(0),last))).rgb;
        if(params[0]>0) color *= smoothstep(params[1]-params[2],params[1]+params[2],luminance(color));
        sum += w*color; weight += w;
    }
    return sum/max(weight,1e-12f);
}
kernel void opticalReduce(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    dst.write(float4(areaReduced(src,id,float2(src.get_width(),src.get_height()),float2(dst.get_width(),dst.get_height()),int2(0),p),1),id);
}
kernel void softenCombineReduced(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> blurred[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 scale = float2(blurred.get_width(),blurred.get_height())/float2(dst.get_width(),dst.get_height());
    float2 position = (float2(id)+0.5)*scale-0.5;
    int2 origin = int2(0);
    float3 color = src.read(id).rgb;
    dst.write(float4(mix(color,resizePixel(blurred,position,origin),p[0]),1),id);
}
kernel void glowCombineReduced(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> near[[texture(2)]],texture2d<float,access::read> far[[texture(3)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 scale = float2(near.get_width(),near.get_height())/float2(dst.get_width(),dst.get_height());
    float2 position = (float2(id)+0.5)*scale-0.5;
    int2 origin = int2(0);
    float3 color = src.read(id).rgb;
    float3 hi = color*smoothstep(p[2]-p[3],p[2]+p[3],luminance(color));
    float3 spread = mix(resizePixel(near,position,origin),resizePixel(far,position,origin),p[1]);
    dst.write(float4(color+p[0]*(spread-hi),1),id);
}
kernel void halationCombineReduced(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> near[[texture(2)]],texture2d<float,access::read> mid[[texture(3)]],texture2d<float,access::read> far[[texture(4)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 scale = float2(near.get_width(),near.get_height())/float2(dst.get_width(),dst.get_height());
    float2 position = (float2(id)+0.5)*scale-0.5;
    int2 origin = int2(0);
    float3 color = src.read(id).rgb;
    float hi = luminance(color)*smoothstep(p[4]-p[5],p[4]+p[5],luminance(color));
    float3 scales = float3(luminance(resizePixel(near,position,origin)),luminance(resizePixel(mid,position,origin)),luminance(resizePixel(far,position,origin)));
    dst.write(float4(color+halationResidual(scales,hi)*p[0]*float3(p[1],p[2],p[3]),1),id);
}

// Regional kernels use complete-frame coordinates and local texture storage.
kernel void vignetteRegion(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],constant float* g[[buffer(2)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float2 size=float2(g[2],g[3]);float r=min(1.0,length(float2(id)+float2(g[0],g[1])+0.5-size*float2(p[3],p[4]))/(length(size)*0.5));float curve=pow(smoothstep(p[1],1.0,r),p[2]);dst.write(float4(src.read(id).rgb*exp2(-p[0]*curve),1),id);
}
kernel void randomFieldRegion(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],constant float* g[[buffer(2)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;uint v=hashValue(id.x+uint(g[0])+(id.y+uint(g[1]))*uint(g[2]))^as_type<uint>(p[0]);dst.write(float4(gaussianRandom(v),gaussianRandom(v^0x68bc21eb),gaussianRandom(v^0x02e5be93),1),id);
}
kernel void resizeLinearRegion(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* g[[buffer(2)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float3 value = resizeSample(src,id+uint2(g[0],g[1]),float2(g[4],g[5]),float2(g[2],g[3]),int2(g[6],g[7]));
    dst.write(float4(value,1),id);
}
kernel void softenCombineReducedRegion(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> blurred[[texture(2)]],constant float* p[[buffer(0)]],constant float* g[[buffer(2)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 scale = float2(g[4],g[5]);
    float2 position = (float2(id+uint2(g[0],g[1]))+0.5)*scale-0.5;
    int2 origin = int2(g[6],g[7]);
    float3 color = src.read(id).rgb;
    dst.write(float4(mix(color,resizePixel(blurred,position,origin),p[0]),1),id);
}
kernel void glowCombineReducedRegion(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> near[[texture(2)]],texture2d<float,access::read> far[[texture(3)]],constant float* p[[buffer(0)]],constant float* g[[buffer(2)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 scale = float2(g[4],g[5]);
    float2 position = (float2(id+uint2(g[0],g[1]))+0.5)*scale-0.5;
    int2 origin = int2(g[6],g[7]);
    float3 color = src.read(id).rgb;
    float3 hi = color*smoothstep(p[2]-p[3],p[2]+p[3],luminance(color));
    float3 spread = mix(resizePixel(near,position,origin),resizePixel(far,position,origin),p[1]);
    dst.write(float4(color+p[0]*(spread-hi),1),id);
}
kernel void halationCombineReducedRegion(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> near[[texture(2)]],texture2d<float,access::read> mid[[texture(3)]],texture2d<float,access::read> far[[texture(4)]],constant float* p[[buffer(0)]],constant float* g[[buffer(2)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    float2 scale = float2(g[4],g[5]);
    float2 position = (float2(id+uint2(g[0],g[1]))+0.5)*scale-0.5;
    int2 origin = int2(g[6],g[7]);
    float3 color = src.read(id).rgb;
    float hi = luminance(color)*smoothstep(p[4]-p[5],p[4]+p[5],luminance(color));
    float3 scales = float3(luminance(resizePixel(near,position,origin)),luminance(resizePixel(mid,position,origin)),luminance(resizePixel(far,position,origin)));
    dst.write(float4(color+halationResidual(scales,hi)*p[0]*float3(p[1],p[2],p[3]),1),id);
}
kernel void opticalReduceRegion(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],constant float* g[[buffer(2)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    dst.write(float4(areaReduced(src,id+uint2(g[6],g[7]),float2(g[2],g[3]),float2(g[8],g[9]),int2(g[0],g[1]),p),1),id);
}

// 恒等帧也可能需要转换纹理存储精度，颜色编码沿用源像素。
kernel void copyPixels(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],uint2 id[[thread_position_in_grid]]) {
    if(outside(id,dst)) return;
    dst.write(src.read(id),id);
}
// 逐像素检查各通道的有限性，非有限标志与 RGB 极值分别记录。
kernel void inputRangeTiles(texture2d<float,access::read> src[[texture(0)]],device float4* result[[buffer(0)]],uint2 tile[[thread_position_in_grid]]) {
    uint nx=(src.get_width()+15)/16, ny=(src.get_height()+15)/16;
    if(tile.x>=nx || tile.y>=ny) return;
    float lo=INFINITY, hi=-INFINITY; bool invalid=false;
    for(uint y=tile.y*16;y<min((tile.y+1)*16,src.get_height());++y) {
        for(uint x=tile.x*16;x<min((tile.x+1)*16,src.get_width());++x) {
            float4 v=src.read(uint2(x,y));
            invalid=invalid || !all(isfinite(v));
            lo=min(lo,min(v.r,min(v.g,v.b))); hi=max(hi,max(v.r,max(v.g,v.b)));
        }
    }
    result[tile.y*nx+tile.x]=float4(lo,hi,invalid ? 1.0f : 0.0f,0);
}

// linear-srgb-summary-v1 在线性光中覆盖整帧，每个像素按与采样格的重叠面积贡献。
kernel void frameFeatureAreaV1(texture2d<float,access::read> input [[texture(0)]],
 device float4* samples [[buffer(0)]], constant uint2& size [[buffer(1)]], uint2 id [[thread_position_in_grid]]) {
 if(any(id>=size))return;
 float2 scale=float2(input.get_width(),input.get_height())/float2(size);
 float2 lo=float2(id)*scale, hi=float2(id+1)*scale;
 float3 total=0; float invalid=0;
 for(uint y=uint(floor(lo.y));y<min(uint(ceil(hi.y)),input.get_height());++y) {
  float wy=max(0.0f,min(hi.y,float(y+1))-max(lo.y,float(y)));
  for(uint x=uint(floor(lo.x));x<min(uint(ceil(hi.x)),input.get_width());++x) {
   float wx=max(0.0f,min(hi.x,float(x+1))-max(lo.x,float(x)));
   float3 c=decodeRGB(input.read(uint2(x,y)).rgb);
   if(!all(isfinite(c)))invalid=1;
   total+=c*(wx*wy/(scale.x*scale.y));
  }
 }
 samples[id.y*size.x+id.x]=float4(total,invalid);
}
// 每个线程最多归约 256 个样本。局部计数可由 Float32 精确表示，记录留在 GPU 私有缓冲区。
kernel void frameFeatureSummaryV1(device const float4* samples [[buffer(0)]], device float* partials [[buffer(1)]],
 constant uint& count [[buffer(2)]], constant float2* requests [[buffer(3)]], constant uint& featureCount [[buffer(4)]], uint id [[thread_position_in_grid]]) {
 uint start=id*256;if(start>=count)return;
 uint bins[256]; for(uint b=0;b<256;++b)bins[b]=0;
 uint thresholds[64]; for(uint f=0;f<featureCount;++f)thresholds[f]=0;
 float3 total=0, correction=0; uint below=0,above=0; float invalid=0;
 for(uint i=start;i<min(start+256,count);++i) {
  float4 sample=samples[i]; float y=luminance(sample.rgb);
  if(sample.w!=0 || !all(isfinite(sample)) || !isfinite(y)){invalid=1;continue;}
  float3 adjusted=sample.rgb-correction, next=total+adjusted;
  correction=(next-total)-adjusted;total=next;
  // 直方图将越界亮度归入端点区间，越界比例和阈值使用原始线性亮度。
  bins[min(255u,uint(clamp(y,0.0f,1.0f)*256))]++;
  below+=y<0;above+=y>1;
  for(uint f=0;f<featureCount;++f) {
   thresholds[f]+=(requests[f].x==1 && y<=requests[f].y)||(requests[f].x==2 && y>=requests[f].y);
  }
 }
 uint offset=id*(262+featureCount);
 for(uint b=0;b<256;++b)partials[offset+b]=float(bins[b]);
 partials[offset+256]=total.r;partials[offset+257]=total.g;partials[offset+258]=total.b;
 partials[offset+259]=float(below);partials[offset+260]=float(above);partials[offset+261]=invalid;
 for(uint f=0;f<featureCount;++f)partials[offset+262+f]=float(thresholds[f]);
}
// 每个输出分量由一个线程合并最多 256 份局部结果，两级归约使用禁用快速数学的补偿求和。
kernel void frameFeatureCombineV1(device const float* partials [[buffer(0)]], device float* output [[buffer(1)]],
 constant uint& count [[buffer(2)]], constant uint& partitions [[buffer(3)]], constant uint& featureCount [[buffer(4)]], uint id [[thread_position_in_grid]]) {
 uint stride=262+featureCount;if(id>=stride)return;
 float total=0,correction=0;
 for(uint p=0;p<partitions;++p) {
  float adjusted=partials[p*stride+id]-correction,next=total+adjusted;
  correction=(next-total)-adjusted;total=next;
 }
 output[id]=(id>=256 && id!=261)?total/float(count):total;
}

// 各常驻 LUT 采样同一编码输入，在一个阶段用 Float32 累加并按权重和归一化。
kernel void weightedLUTMap(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],
 texture3d<float,access::read> a[[texture(2)]],texture3d<float,access::read> b[[texture(3)]],
 texture3d<float,access::read> c[[texture(4)]],texture3d<float,access::read> d[[texture(5)]],
 constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;
 float3 input=src.read(id).rgb, result=0;bool extrapolate=p[4]>0;
 if(p[0]>0)result+=p[0]*sampleCube(input,a,extrapolate);
 if(p[1]>0)result+=p[1]*sampleCube(input,b,extrapolate);
 if(p[2]>0)result+=p[2]*sampleCube(input,c,extrapolate);
 if(p[3]>0)result+=p[3]*sampleCube(input,d,extrapolate);
 dst.write(float4(result/(p[0]+p[1]+p[2]+p[3]),1),id);
}
