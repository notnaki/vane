from pathlib import Path
import subprocess,sys
r=Path(__file__).resolve().parents[2];baseline='--baseline' in sys.argv
def read(name):
 if baseline:return subprocess.check_output(['git','show','d808ddf:Sources/Vane/'+name],cwd=r,text=True)
 return (r/'Sources/Vane'/name).read_text()
def block(s,st):
 a=s.index(st);b=s.index('{',a);i=b+1;depth=1
 while depth:
  if s[i]=='{':depth+=1
  elif s[i]=='}':depth-=1
  i+=1
 return s[a:i]
s='''import Foundation
@MainActor enum ProfileManager {
 nonisolated static func suffix(_ id:UUID)->String { "-"+id.uuidString }
 nonisolated static func defaultsKey(_ key:String,_ id:UUID)->String {key+suffix(id)}
 nonisolated static func sessionURL(for id:UUID,in directory:URL)->URL {directory.appendingPathComponent("session"+suffix(id)+".json")}
 nonisolated static func spacesURL(for id:UUID,in directory:URL)->URL {directory.appendingPathComponent("spaces"+suffix(id)+".json")}
}
'''
s+=block(read('Suspension.swift'),'enum SnapshotPersistence')+'\n'+block(read('Suspension.swift'),'struct Parked')+'\n'
s+=read('RecoverySnapshots.swift')+'\n'
if not baseline:s+=(r/'Sources/Vane/SessionPersistence.swift').read_text()+'\n'
s+='@MainActor enum Suspension {\n'+('@MainActor ' if not baseline else '')+block(read('Suspension.swift'),'enum SpaceState')+'\n}\n'
boost=read('SiteBoosts.swift');s+=block(boost,'struct SiteBoost:')+'\n';a=boost.index('@MainActor final class SiteBoostStore');b=boost.index('\n@MainActor enum SiteBoosts',a);s+=boost[a:b]+'\n'
s+='@MainActor enum SiteBoosts {\n'+block(boost,'nonisolated static func origin(')+'\n}\n'
s+='''
@main struct Probe {
 @MainActor static func main() async throws {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("vane-task5-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  defer {try? FileManager.default.removeItem(at:directory)}
  let profile=UUID(),space=UUID()
  let rows=["https://example.com":Parked(title:"A",state:Data("opaque".utf8))]
  precondition(Suspension.SpaceState.save(rows,space:space,profileID:profile,in:directory))
  precondition(Suspension.SpaceState.save(rows,space:space,profileID:profile,in:directory))
  let previous=Suspension.SpaceState.url(for:profile,in:directory).appendingPathExtension("previous")
  let unchangedOK = !FileManager.default.fileExists(atPath:previous.path)
  print("unchanged save avoids generation rewrite: \\(unchangedOK)")
  let suite="vane-task5-"+UUID().uuidString;let defaults=UserDefaults(suiteName:suite)!
  defer {defaults.removePersistentDomain(forName:suite)}
  var boost=SiteBoost();boost.css=String(repeating:"a",count:54000)
  let table=Dictionary(uniqueKeysWithValues:(0..<1000).map{("https://site\\($0).example",boost)})
  defaults.set(try JSONEncoder().encode(table),forKey:SiteBoostStore.key(profile))
  let store=SiteBoostStore(defaults:defaults)
  _=store.get(origin:"https://site0.example",profile:profile)
  let start=Date()
  for _ in 0..<3 {precondition(store.get(origin:"https://site0.example",profile:profile).css.count==54000)}
  let elapsed=Date().timeIntervalSince(start)
  print("three warm Boost lookups seconds=\\(elapsed), suite=\\(suite)")
  if !unchangedOK || elapsed > 0.05 { print("FAIL");exit(1) }
  print("PASS")
 }
}
'''
out='/tmp/vane-task5-persistence'+('-baseline' if baseline else '')
Path(out+'.swift').write_text(s)
c=subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-O',out+'.swift','-o',out],capture_output=True,text=True);print(c.stdout+c.stderr)
if c.returncode:sys.exit(c.returncode)
sys.exit(subprocess.run([out]).returncode)
