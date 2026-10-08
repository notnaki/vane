import Foundation

enum UpdateRelaunch {
    static func script(parentPID: Int32, target: URL, isolatedDirectory: String?,
                       opener: URL = URL(fileURLWithPath: "/usr/bin/open"),
                       verifier: URL = URL(fileURLWithPath: "/usr/bin/codesign"),
                       recoveryTool: URL? = nil, directExecutable: URL? = nil) -> String {
        func quoted(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let environment = isolatedDirectory.map { "--env " + quoted("VANE_DATA_DIR=" + $0) + " " } ?? ""
        let check = quoted(verifier.path) + " --verify --deep --strict --all-architectures -R "
            + quoted("=identifier \"io.github.notnaki.vane\"") + " " + quoted(target.path)
        let wait = "while kill -0 \(parentPID) 2>/dev/null; do sleep 0.1; done; "
        if let recoveryTool {
            // The existing signed helper gets LaunchServices' exact application object,
            // so it can distinguish a live slow bootstrap from a failed launch.
            let isolated = isolatedDirectory.map { "VANE_DATA_DIR=" + quoted($0) + " " } ?? ""
            let trusted = quoted(verifier.path) + " --verify --deep --strict --all-architectures -R "
                + quoted("=" + UpdateInstaller.requirement(identifier: "io.github.notnaki.vane"))
                + " " + quoted(target.path)
            let helper = quoted(verifier.path) + " --verify --strict -R "
                + quoted("=" + UpdateInstaller.requirement(identifier: UpdateInstaller.serviceName))
                + " " + quoted(recoveryTool.path)
            return wait + trusted + " && " + helper + " || exit 1; "
                + isolated + quoted(recoveryTool.path) + " --relaunch " + quoted(target.path)
        }
        if let directExecutable, let isolatedDirectory {
            // LaunchServices ignores environment overrides inherited from a sandbox.
            // Developer/test copies must retain isolation across rollback as well.
            return wait + check + " || exit 1; VANE_DATA_DIR=" + quoted(isolatedDirectory)
                + " " + quoted(directExecutable.path)
        }
        return wait + check + " || exit 1; "
            + "for i in 1 2 3; do \(quoted(opener.path)) -n \(environment)\(quoted(target.path)) && exit 0; sleep 1; done; exit 1"
    }
}
