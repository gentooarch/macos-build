import Foundation

// 1. 获取命令行参数
// CommandLine.arguments[0] 是程序名，所以 argc != 4 对应 arguments.count != 4
let args = CommandLine.arguments

if args.count != 4 {
    let programName = (args[0] as NSString).lastPathComponent
    print("Usage: \(programName) initial_amount final_amount years")
    print("Examples:")
    print("  \(programName) 100000 180000 5")
    print("  \(programName) 50000 120000 3.75")
    exit(1)
}

// 2. 解析参数并转换为 Double
guard let initial = Double(args[1]),
      let final = Double(args[2]),
      let years = Double(args[3]) else {
    print("Error: All arguments must be valid numbers.")
    exit(1)
}

// 3. 逻辑校验
if initial <= 0 {
    print("Error: Initial amount must be greater than 0")
    exit(1)
}

if years <= 0 {
    print("Error: Years must be greater than 0")
    exit(1)
}

if final < 0 {
    print("Warning: Final amount is negative (result may not be meaningful)")
}

let ratio = final / initial
if ratio <= 0 {
    print("Cannot calculate annualized rate (ratio <= 0)")
    exit(1)
}

// 4. 计算年化收益率 (CAGR)
// Swift 中使用 Foundation 库提供的 pow 函数
let annualized = pow(ratio, 1.0 / years) - 1.0

// 5. 格式化输出结果
// 使用 String(format:) 来模拟 C 语言的 printf 精度控制
print(String(format: "Initial amount: %.2f", initial))
print(String(format: "Final amount  : %.2f", final))
print(String(format: "Years held    : %.4f", years))
print(String(format: "Annualized return: %.4f%%  (%.6f)", annualized * 100.0, annualized))

// 6. 性能评价
if annualized > 0.20 {
    print("→ Excellent annualized performance!")
} else if annualized > 0.10 {
    print("→ Very good long-term return")
} else if annualized > 0.05 {
    print("→ Solid positive return")
} else if annualized > 0 {
    print("→ Beats inflation, but not outstanding")
} else {
    print("→ Actually a loss (negative annualized return)")
}
