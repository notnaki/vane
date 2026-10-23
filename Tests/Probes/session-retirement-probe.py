from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
source = (repo / "Sources/Vane/SessionPersistence.swift").read_text()
source += r'''
@main struct RetirementProbe {
 static func main() async throws {
  let lane=SessionPersistence(),root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:root)}
  let file=root.appendingPathComponent("session.json"),release=DispatchSemaphore(value:0),entered=DispatchSemaphore(value:0)
  lane.enqueue(file:file) { entered.signal();release.wait();try? Data("old".utf8).write(to:file);return false }
  await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in DispatchQueue.global().async {entered.wait();c.resume()} }
  let retirement=Task {await lane.retire(files:[file])}
  while lane.enqueue(file:file,{try? Data("queued".utf8).write(to:file);return true}) {await Task.yield()}
  release.signal();await retirement.value
  try FileManager.default.removeItem(at:file)
  precondition(!lane.enqueue(file:file,{try? Data("future".utf8).write(to:file);return true}))
  let ok=await lane.flush();precondition(ok)
  precondition(!FileManager.default.fileExists(atPath:file.path))
  print("PASS retired destination rejects queued/future writes and failed retry after active writer drains")
 }
}

'''
with tempfile.TemporaryDirectory(prefix="vane-session-retirement-") as temporary:
    root = Path(temporary)
    swift = root / "probe.swift"
    swift.write_text(source)
    binary = root / "probe"
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
