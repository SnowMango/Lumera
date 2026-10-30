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
kernel void lutMap(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture3d<float,access::read> lut[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;
 float3 coord=clamp(src.read(id).rgb,0.0,1.0)*float(lut.get_width()-1);uint3 lo=uint3(floor(coord)),hi=min(lo+1,uint3(lut.get_width()-1));float3 f=fract(coord);
 float3 a=mix(lut.read(uint3(lo.x,lo.y,lo.z)).rgb,lut.read(uint3(hi.x,lo.y,lo.z)).rgb,f.x);
 float3 b=mix(lut.read(uint3(lo.x,hi.y,lo.z)).rgb,lut.read(uint3(hi.x,hi.y,lo.z)).rgb,f.x);
 float3 c=mix(lut.read(uint3(lo.x,lo.y,hi.z)).rgb,lut.read(uint3(hi.x,lo.y,hi.z)).rgb,f.x);
 float3 d=mix(lut.read(uint3(lo.x,hi.y,hi.z)).rgb,lut.read(uint3(hi.x,hi.y,hi.z)).rgb,f.x);
 dst.write(float4(mix(mix(a,b,f.y),mix(c,d,f.y),f.z),1),id);
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
kernel void resizeLinear(texture2d<float,access::sample> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 // Area supersampling prevents the worst aliasing when reducing photos.
 float2 dstSize=float2(dst.get_width(),dst.get_height());int steps=min(8,max(1,int(ceil(max(float(src.get_width())/dst.get_width(),float(src.get_height())/dst.get_height())))));
 float4 sum=0;for(int y=0;y<steps;y++)for(int x=0;x<steps;x++)sum+=src.sample(s,(float2(id)+(float2(x,y)+0.5)/steps)/dstSize);
 dst.write(float4((sum/float(steps*steps)).rgb,1),id);
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
kernel void finish(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> luma[[texture(2)]],texture2d<float,access::read> chroma[[texture(3)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]){
 if(outside(id,dst))return;float3 c=encodeRGB(src.read(id).rgb);
 if(p[0]>0){float sigma=clamp(responseValue(luminance(c),p+4)*p[3],0.0f,0.1f);
 float dn=luma.read(id).r*sigma;float2 z=chroma.read(id).gb;float cb=z.x*sigma*p[1],cr=(p[2]*z.x+sqrt(1-p[2]*p[2])*z.y)*sigma*p[1];c+=float3(dn+1.5748*cr,dn-0.187324*cb-0.468124*cr,dn+1.8556*cb);
 }dst.write(float4(clamp(c,0.0,1.0),1),id);
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
kernel void softenCombine(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> blurred[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;dst.write(float4(mix(src.read(id).rgb,blurred.read(id).rgb,p[0]),1),id);
}
kernel void halationCombine(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::read> sourceLight[[texture(2)]],texture2d<float,access::read> scatteredLight[[texture(3)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;
 float halo=max(0.0f,luminance(scatteredLight.read(id).rgb)-luminance(sourceLight.read(id).rgb));
 dst.write(float4(src.read(id).rgb+halo*p[0]*float3(p[1],p[2],p[3]),1),id);
}
// Variance-normalized value noise, with continuous spatial correlation and no bitmap upload.
float grainField(float2 xy,uint seed) {
 int2 base=int2(floor(xy));float2 f=fract(xy);f=f*f*(3-2*f);
 float4 w=float4((1-f.x)*(1-f.y),f.x*(1-f.y),(1-f.x)*f.y,f.x*f.y);
 uint x=uint(base.x),y=uint(base.y);
 float4 n=float4(gaussianRandom(hashValue(x)^hashValue(y+0x91e10da5u)^seed),
 gaussianRandom(hashValue(x+1)^hashValue(y+0x91e10da5u)^seed),
 gaussianRandom(hashValue(x)^hashValue(y+1+0x91e10da5u)^seed),
 gaussianRandom(hashValue(x+1)^hashValue(y+1+0x91e10da5u)^seed));
 return dot(n,w)/sqrt(max(dot(w,w),1e-6f));
}
float filmField(float2 xy,uint seed,float roughness) {
 float a=grainField(xy,seed),b=grainField(xy*0.4f+float2(13.7f,29.1f),seed^0xa341316cu);
 return mix(a,b,roughness)/sqrt((1-roughness)*(1-roughness)+roughness*roughness);
}
kernel void filmGrain(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;
 float3 c=src.read(id).rgb;float y=clamp(luminance(c),0.0f,1.0f);
 float2 xy=(float2(id)+0.5f)/max(p[1],0.5f);uint seed=as_type<uint>(p[4]);
 float n=filmField(xy,seed,p[2]),cb=filmField(xy,seed^0x68bc21ebu,p[2])*p[3],cr=filmField(xy,seed^0x02e5be93u,p[2])*p[3];
 float amplitude=p[0]*responseValue(y,p+5);
 c+=amplitude*float3(n+1.5748f*cr,n-0.187324f*cb-0.468124f*cr,n+1.8556f*cb);
 dst.write(float4(clamp(c,0.0f,1.0f),1),id);
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
kernel void opticalReduce(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;
 float2 ratio=float2(src.get_width(),src.get_height())/float2(dst.get_width(),dst.get_height());
 float2 lower=float2(id)*ratio,upper=min((float2(id)+1)*ratio,float2(src.get_width(),src.get_height()));
 uint2 begin=uint2(floor(lower)),end=min(uint2(ceil(upper)),uint2(src.get_width(),src.get_height()));
 float3 sum=0;float weight=0;
 for(uint y=begin.y;y<end.y;y++)for(uint x=begin.x;x<end.x;x++) {
   float w=max(0.0f,min(upper.x,float(x+1))-max(lower.x,float(x)))*max(0.0f,min(upper.y,float(y+1))-max(lower.y,float(y)));
   float3 c=src.read(uint2(x,y)).rgb;
   if(p[0]>0) c*=smoothstep(p[1]-p[2],p[1]+p[2],luminance(c));
   sum+=w*c;weight+=w;
 }
 dst.write(float4(sum/max(weight,1e-12f),1),id);
}
kernel void softenCombineReduced(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::sample> blurred[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 uv=(float2(id)+0.5)/float2(dst.get_width(),dst.get_height());
 dst.write(float4(mix(src.read(id).rgb,blurred.sample(s,uv).rgb,p[0]),1),id);
}
kernel void glowCombineReduced(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::sample> near[[texture(2)]],texture2d<float,access::sample> far[[texture(3)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 uv=(float2(id)+0.5)/float2(dst.get_width(),dst.get_height());float3 c=src.read(id).rgb;
 float3 hi=c*smoothstep(p[2]-p[3],p[2]+p[3],luminance(c));
 dst.write(float4(c+p[0]*(mix(near.sample(s,uv).rgb,far.sample(s,uv).rgb,p[1])-hi),1),id);
}
kernel void halationCombineReduced(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],texture2d<float,access::sample> scattered[[texture(2)]],constant float* p[[buffer(0)]],uint2 id[[thread_position_in_grid]]) {
 if(outside(id,dst))return;constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float2 uv=(float2(id)+0.5)/float2(dst.get_width(),dst.get_height());float3 c=src.read(id).rgb;
 float hi=luminance(c)*smoothstep(p[4]-p[5],p[4]+p[5],luminance(c));
 float halo=max(0.0f,luminance(scattered.sample(s,uv).rgb)-hi);
 dst.write(float4(c+halo*p[0]*float3(p[1],p[2],p[3]),1),id);
}
