from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
def block(text, start):
    first = text.index(start)
    index = text.index('{', first) + 1
    depth = 1
    while depth:
        depth += (text[index] == '{') - (text[index] == '}')
        index += 1
    return text[first:index]
suspension = (repo / 'Sources/Vane/Suspension.swift').read_text()
source = '''import Foundation
@MainActor enum ProfileManager {
 nonisolated static func suffix(_ id:UUID)->String { "-"+id.uuidString }
 nonisolated static func sessionURL(for id:UUID,in directory:URL)->URL {directory.appendingPathComponent("session"+suffix(id)+".json")}
 nonisolated static func spacesURL(for id:UUID,in directory:URL)->URL {directory.appendingPathComponent("spaces"+suffix(id)+".json")}
}
'''
source += block(suspension, 'enum SnapshotPersistence') + '\n' + block(suspension, 'struct Parked') + '\n'
source += (repo / 'Sources/Vane/RecoverySnapshots.swift').read_text() + '\n'
source += (repo / 'Sources/Vane/SessionPersistence.swift').read_text() + '\n'
source += '@MainActor enum Suspension {\n@MainActor ' + block(suspension, 'enum SpaceState') + '\n}\n'
window = (repo / 'Sources/Vane/Window.swift').read_text()
split = (repo / 'Sources/Vane/SplitView.swift').read_text()
source += "enum TabKind:Int,Codable,Sendable {case today,pinned,favourite}\n"
source += "enum TabAddress {static func restorable(_ url:URL?)->Bool {url?.scheme == \"https\" || url?.scheme == \"http\"}}\n"
source += "struct Split {" + block(split, '    struct Saved:') + "}\n"
source += "@MainActor enum Session {static var directory=URL(fileURLWithPath: \"/tmp\");private static func file(_ id:UUID)->URL {ProfileManager.sessionURL(for:id,in:directory)}\n"
for declaration in ['    struct Entry:', '    private struct Disk:', '    struct RestorationSnapshot:',
                    '    nonisolated static func encode(', '    nonisolated static func readable(',
                    '    private nonisolated static func restorationSnapshot(', '    struct StagedForget:',
                    '    static func stageForget(space id:', '    static func stageForget(spaces:',
                    '    static func repair(_ change: StagedForget)',
                    '    private nonisolated static func forgetFile(space id:',
                    '    private nonisolated static func forgetFile(spaces removed:']:
    source += block(window, declaration) + "\n"
source += "}\n"
source += r'''
final class ProbeWritePermission: @unchecked Sendable {
 private let lock=NSLock();private var allowed=false
 func permits()->Bool {lock.withLock {allowed}}
 func allow(){lock.withLock {allowed=true}}
}
@main struct RepairProbe {
 @MainActor static func main() async throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:directory)}
  let profile=UUID(),a=UUID(),b=UUID(),page="https://repair.example"
  let old=[page:Parked(title:"Old",state:Data([1]))]
  let original=[page:Parked(title:"Original",state:Data([1,2,3]))]
  Suspension.SpaceState.registerNewProfile(profileID:profile,in:directory)
  precondition(Suspension.SpaceState.save(old,space:a,profileID:profile,in:directory))
  precondition(Suspension.SpaceState.save(original,space:a,profileID:profile,in:directory))
  let file=Suspension.SpaceState.url(for:profile,in:directory)
  let before=try RecoverySnapshots.Generations.capture(file)
  let staged=await Suspension.SpaceState.stageSave([:],space:a,profileID:profile,in:directory)
  precondition(staged.succeeded)
  let repaired=await Suspension.SpaceState.repair(staged.change!)
  precondition(repaired)
  precondition(try RecoverySnapshots.Generations.capture(file)==before)
  precondition(Suspension.SpaceState.load(space:a,profileID:profile,in:directory)==original)
  let next=await Suspension.SpaceState.stageSave([:],space:a,profileID:profile,in:directory)
  let newerB=[page:Parked(title:"Newer B")]
  let savedB=await Suspension.SpaceState.saveAsync(newerB,space:b,profileID:profile,in:directory)
  precondition(savedB)
  let merged=await Suspension.SpaceState.repair(next.change!)
  precondition(merged)
  precondition(Suspension.SpaceState.load(space:a,profileID:profile,in:directory)==original)
  precondition(Suspension.SpaceState.load(space:b,profileID:profile,in:directory)==newerB)
  let third=await Suspension.SpaceState.stageSave([:],space:a,profileID:profile,in:directory)
  let newerA=[page:Parked(title:"Newer A")]
  let savedA=await Suspension.SpaceState.saveAsync(newerA,space:a,profileID:profile,in:directory)
  precondition(savedA)
  let skipped=await Suspension.SpaceState.repair(third.change!)
  precondition(skipped)
  precondition(Suspension.SpaceState.load(space:a,profileID:profile,in:directory)==newerA)
  let fallback=try Data(contentsOf:file)
  try fallback.write(to:file.appendingPathExtension("previous"))
  try Data("{broken".utf8).write(to:file)
  let paused=Suspension.SpaceState.load(space:b,profileID:profile,in:directory)
  precondition(paused[page]?.needsRecovery==true)
  precondition(Suspension.SpaceState.remove(space:a,profileID:profile,in:directory))
  precondition(Suspension.SpaceState.load(space:b,profileID:profile,in:directory)[page]?.needsRecovery==true)
  Session.directory=directory
  let sessionFile=ProfileManager.sessionURL(for:profile,in:directory)
  let originalSession=Session.encode([[Session.Entry(url:page)],[Session.Entry(url:"https://other.example")]],spaces:[a.uuidString,b.uuidString])!
  try originalSession.write(to:sessionFile)
  let sessionBefore=try RecoverySnapshots.Generations.capture(sessionFile)
  let forgotten=await Session.stageForget(spaces:[a,b],in:profile)
  precondition(forgotten.succeeded)
  let sessionRepaired=await Session.repair(forgotten.change!)
  precondition(sessionRepaired)
  let sessionAfter=try RecoverySnapshots.Generations.capture(sessionFile)
  precondition(sessionAfter==sessionBefore)
  let forgottenAgain=await Session.stageForget(space:a,in:profile)
  let newerSession=Session.encode([[Session.Entry(url:"https://newer.example")]],spaces:[a.uuidString])!
  SessionPersistence.shared.enqueue(file:sessionFile) {try? newerSession.write(to:sessionFile);return true}
  let flushed=await SessionPersistence.shared.flush();precondition(flushed)
  let skipSession=await Session.repair(forgottenAgain.change!);precondition(skipSession)
  let retainedSession=try Data(contentsOf:sessionFile);precondition(retainedSession==newerSession)
  let pendingFile=directory.appendingPathComponent("pending-session.json")
  let lane=SessionPersistence(),permission=ProbeWritePermission()
  lane.enqueue(file:pendingFile) {permission.permits() && SnapshotPersistence.write(Data("old pending".utf8),to:pendingFile)}
  let rejected=await lane.flush();precondition(!rejected)
  let stagedPending=await lane.mutate(file:pendingFile) {SnapshotPersistence.write(Data("staged".utf8),to:pendingFile)}
  let stagedFlushed=await lane.flush();precondition(stagedFlushed)
  permission.allow()
  let rolledBack=await lane.repair(stagedPending!.ownership) { owns in
   precondition(owns);return (true,SessionPersistence.RepairDisposition.rolledBack)
  };precondition(rolledBack==true)
  let pendingFlushed=await lane.flush();precondition(pendingFlushed)
  let pendingBytes=try Data(contentsOf:pendingFile);precondition(pendingBytes==Data("old pending".utf8))
  let closedProfile=UUID(),removedSpace=UUID(),keptSpace=UUID(),closedPermission=ProbeWritePermission()
  let closedFile=ProfileManager.sessionURL(for:closedProfile,in:directory)
  let closedOld=Session.encode([[Session.Entry(url:"https://old-closed.example")]],spaces:[removedSpace.uuidString])!
  let closedPending=Session.encode([[Session.Entry(url:"https://remove.example")],[Session.Entry(url:"https://keep-accepted.example")]],spaces:[removedSpace.uuidString,keptSpace.uuidString])!
  try closedOld.write(to:closedFile)
  SessionPersistence.shared.enqueue(file:closedFile) {closedPermission.permits() && RecoverySnapshots.write(closedPending,to:closedFile,valid:Session.readable)}
  let closedRejected=await SessionPersistence.shared.flush();precondition(!closedRejected)
  let closedBlocked=await Session.stageForget(space:removedSpace,in:closedProfile);precondition(!closedBlocked.succeeded && closedBlocked.change==nil)
  closedPermission.allow()
  let closedStaged=await Session.stageForget(space:removedSpace,in:closedProfile);precondition(closedStaged.succeeded)
  let closedData=try String(contentsOf:closedFile,encoding:.utf8);precondition(closedData.contains("keep-accepted.example") && !closedData.contains("remove.example"))
  let closedRepair=await Session.repair(closedStaged.change!);precondition(closedRepair)
  let closedRestored=try Data(contentsOf:closedFile);precondition(closedRestored==closedPending)
  print("PASS exact session/sidecar generations and caches, unrelated merge, newer writes, external fallback pause, retry ownership and pending closed-window preservation")
 }
}
'''
# Throwing expressions are evaluated outside precondition's nonthrowing autoclosure.
source = source.replace('precondition(try RecoverySnapshots.Generations.capture(file)==before)',
                        'let restored=try RecoverySnapshots.Generations.capture(file);precondition(restored==before)')
with tempfile.TemporaryDirectory(prefix='vane-session-repair-') as temporary:
    root=Path(temporary);swift=root/'probe.swift';binary=root/'probe'
    swift.write_text(source)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
