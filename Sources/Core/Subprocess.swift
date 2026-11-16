import Foundation

/// 调外部命令并收结果。所有起子进程的地方都走这里，别再各写一份 Pipe。
enum Subprocess {
    struct Output {
        let status: Int32
        let data: Data
    }

    /// `mergeStderr` 为真时 stderr 并在 stdout 里一起收。
    static func capture(_ executable: String, _ arguments: [String],
                        environment: [String: String]? = nil,
                        currentDirectory: String? = nil,
                        mergeStderr: Bool = false) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        try process.run()
        // 管道两端都要自己关：只靠对象释放的话，跑满上千个会话会一直攒着描述符，
        // 最后 spawn 失败只报一句 "Bad file descriptor"，看不出是漏了句柄。
        // 写端先关，子进程退出时读端才收得到 EOF。
        try? pipe.fileHandleForWriting.close()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: data)
    }
}

/// 同步一个会话要起两次 zstd，句柄是按会话攒起来的。系统给图形应用的软限制
/// 有时只有几百，抬到硬限制后即使别处再漏几个也不会卡在九成进度上。
enum FileDescriptorLimit {
    static func raise(ceiling: Int = 65_536) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let hard = limit.rlim_max
        let target = min(hard, rlim_t(ceiling))
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        setrlimit(RLIMIT_NOFILE, &limit)
    }
}

enum ErrorText {
    /// 句柄耗尽时系统只给一句 “Bad file descriptor”，翻成能照着处理的话。
    static func fileDescriptorHint(_ ns: NSError) -> String? {
        guard ns.domain == NSPOSIXErrorDomain else { return nil }
        switch ns.code {
        case Int(EBADF), Int(EMFILE), Int(ENFILE):
            return "文件句柄不够用，同步中断（已写入的部分都已回滚）；关掉不用的程序再试，或者分批同步"
        default:
            return nil
        }
    }
}
