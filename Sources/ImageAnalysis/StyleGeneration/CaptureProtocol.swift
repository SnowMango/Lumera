import Foundation
import ImagingCore

public enum CaptureRole:String,Codable,CaseIterable,Sendable {case input,target}
public enum CapturePurpose:String,Codable,Sendable {case training,validation}
public enum CaptureTarget:String,Codable,CaseIterable,Sendable {case composite,flat,light}
public struct CaptureDevice:Codable,Equatable,Sendable {
    public var id:String,isoLevels:[Double],baseExposureSeconds:Double
    public init(id:String,isoLevels:[Double],baseExposureSeconds:Double) {self.id=id;self.isoLevels=isoLevels;self.baseExposureSeconds=baseExposureSeconds}
    public func validate() throws {
        guard !id.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,isoLevels.count==3,
              isoLevels.allSatisfy({$0.isFinite && $0>0}),isoLevels[0]<isoLevels[1],isoLevels[1]<isoLevels[2],
              baseExposureSeconds.isFinite,baseExposureSeconds>0 else {throw LabError.invalid("需要实际支持的低、中、高三档 ISO 和试拍基准快门；未知不能填 0")}
    }
}
public struct CaptureStep:Codable,Equatable,Sendable,Identifiable {
    public var id:String,role:CaptureRole,target:CaptureTarget,conditionIndex:Int,exposureEV:Double,repeatIndex:Int,purpose:CapturePurpose
    public var expectedISO:Double,expectedExposureSeconds:Double
    public var pairKey:String {"\(target.rawValue)-\(conditionIndex)-\(exposureEV)-\(repeatIndex)"}
    public var instructions:String {
        let scene:String
        switch target {
        case .composite:scene="正对同一张综合板，四个定位码完整入镜，固定焦段、对焦、白平衡与灯光。"
        case .flat:scene="拍平整均匀区域，使其填满画面，不带边框或定位码；相机固定在三脚架，重复拍摄间不移动。"
        case .light:scene="固定相机、光源、孔径与距离；亮源置于暗背景，改变曝光不改变灯的位置或孔径。"
        }
        return scene+" ISO \(expectedISO.formatted())，快门约 \(expectedExposureSeconds.formatted(.number.precision(.fractionLength(5)))) s，第 \(repeatIndex+1) 张。实际参数以文件元数据核验；超出设备能力需重新试拍规划。"
    }
}
public struct CaptureProtocol:Codable,Equatable,Sendable {
    public let version="capture-draft-1",targetVersion="LM1"
    public var input:CaptureDevice,target:CaptureDevice
    public var steps:[CaptureStep]
    private enum CodingKeys:String,CodingKey {case version,targetVersion,input,target,steps}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        let input=try c.decode(CaptureDevice.self,forKey:.input),target=try c.decode(CaptureDevice.self,forKey:.target)
        try self.init(input:input,target:target)
        guard try c.decode(String.self,forKey:.version)==version,try c.decode(String.self,forKey:.targetVersion)==targetVersion,try c.decode([CaptureStep].self,forKey:.steps)==steps else {throw LabError.invalid("采集协议版本或步骤不匹配，不能恢复旧的划分")}
    }
    public func validate() throws {
        let rebuilt=try CaptureProtocol(input:input,target:target)
        guard steps==rebuilt.steps else {throw LabError.invalid("采集步骤已变更，需按当前协议重新规划")}
    }
    public init(input:CaptureDevice,target:CaptureDevice) throws {
        try input.validate();try target.validate()
        guard input.id != target.id else {throw LabError.invalid("输入设备与目标设备需要独立标识")}
        self.input=input;self.target=target;steps=[]
        for role in CaptureRole.allCases {
            let device=role == .input ? input:target
            for family in CaptureTarget.allCases {
                for level in (family == .light ? [0]:[0,1,2]) {
                    for ev in [-1.0,0,1] {
                        for index in 0..<(family == .flat ? 4:3) {
                            let purpose:CapturePurpose=(level==1 || index==(family == .flat ? 3:2)) ? .validation:.training
                            let duration=device.baseExposureSeconds*(device.isoLevels[0]/device.isoLevels[level])*pow(2,ev)
                            guard duration.isFinite,duration>0 else {throw LabError.invalid("建议快门超出可表示范围，请检查设备参数")}
                            steps.append(.init(id:"\(role.rawValue)-\(family.rawValue)-\(level)-\(Int(ev))-\(index)",role:role,target:family,conditionIndex:level,exposureEV:ev,repeatIndex:index,purpose:purpose,expectedISO:device.isoLevels[level],expectedExposureSeconds:duration))
                        }
                    }
                }
            }
        }
    }
}
public struct CaptureRecord:Codable,Equatable,Sendable {
    public var url:URL,fileDigest:String,step:CaptureStep,actualConditions:CaptureConditions
    public var issues:[String]
}
public struct CaptureSet:Codable,Equatable,Sendable {
    public var protocolVersion:String,records:[CaptureRecord],issues:[String]
    public var canMeasure:Bool {issues.isEmpty && !records.isEmpty && records.allSatisfy{$0.issues.isEmpty}}
}
