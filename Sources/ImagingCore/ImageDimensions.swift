/// Arithmetic validity only. Product resolution and memory budgets belong to the caller.
public enum ImageDimensions {
    public static func pixelCount(width:Int,height:Int) throws -> Int {
        guard width>0,height>0 else {throw LabError.invalid("图像宽高必须为正整数")}
        let (pixels,overflow)=width.multipliedReportingOverflow(by:height)
        guard !overflow,!pixels.multipliedReportingOverflow(by:16).overflow else {
            throw LabError.invalid("图像尺寸导致 RGBA 存储长度溢出")
        }
        return pixels
    }
}
