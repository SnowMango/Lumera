import Foundation
import ImagingCore

/// Low-dimensional double-precision linear algebra on reduced measurements. Never scans image pixels.
enum GenerationMath {
    static func solve(_ a:[[Double]],_ b:[Double]) throws -> [Double] {
        let n=b.count
        guard (1...32).contains(n),a.count==n,a.allSatisfy({$0.count==n && $0.allSatisfy(\.isFinite)}),b.allSatisfy(\.isFinite) else {throw LabError.measurement("求解矩阵无效")}
        var rows=zip(a,b).map{$0+[$1]}
        let scale=a.flatMap{$0}.map{abs($0)}.max() ?? 0
        guard scale>0 else {throw LabError.measurement("样本没有提供足够独立变化")}
        for col in 0..<n {
            let pivot=(col..<n).max{abs(rows[$0][col])<abs(rows[$1][col])}!
            guard abs(rows[pivot][col])>scale*1e-9 else {throw LabError.measurement("样本秩不足或病态，不能可靠区分参数")}
            rows.swapAt(pivot,col);let divisor=rows[col][col]
            for k in col...n {rows[col][k]/=divisor}
            for row in 0..<n where row != col {let factor=rows[row][col];for k in col...n {rows[row][k]-=factor*rows[col][k]}}
        }
        let result=rows.map{$0[n]}
        guard result.allSatisfy(\.isFinite) else {throw LabError.measurement("求解结果不有限")}
        return result
    }
    static func leastSquares(rows:[[Double]],values:[Double]) throws ->[Double] {
        guard let n=rows.first?.count,n>0,rows.count==values.count,rows.count>=n,rows.allSatisfy({$0.count==n}) else {throw LabError.measurement("测量数量不足")}
        var a=Array(repeating:Array(repeating:0.0,count:n),count:n),b=Array(repeating:0.0,count:n)
        for (row,y) in zip(rows,values) {for j in 0..<n {b[j]+=row[j]*y;for k in 0..<n {a[j][k]+=row[j]*row[k]}}}
        return try solve(a,b)
    }
    static func linear(_ v:Double)->Double {v<=0.04045 ? v/12.92:pow((v+0.055)/1.055,2.4)}
    static func encoded(_ v:Double)->Double {v<=0.0031308 ? 12.92*v:1.055*pow(v,1/2.4)-0.055}
}
