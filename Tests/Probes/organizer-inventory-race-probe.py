from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
text = (repo / 'Sources/Vane/TabOrganization.swift').read_text()
start = text.index('    nonisolated static func mergingSpaceChanges(')
index = text.index('{', start) + 1
depth = 1
while depth:
    depth += (text[index] == '{') - (text[index] == '}')
    index += 1
function = text[start:index]
source = '''import Foundation
struct Space: Equatable { var id: UUID; var name: String }
enum Organizer {
''' + function + '''
}
@main struct Probe {
 static func main() async throws {
  let first=Space(id:UUID(),name:"First"),other=Space(id:UUID(),name:"Other"),deleted=Space(id:UUID(),name:"Delete")
  let expected=[first,other,deleted]
  var staged=expected;staged[0].name="Organized"
  let added=Space(id:UUID(),name:"Added")
  var renamed=other;renamed.name="Renamed while disk worker waits"
  let latest=[first,renamed,added]
  guard let result=Organizer.mergingSpaceChanges(staged,expected:expected,latest:latest,affected:[first.id]),
        result==[staged[0],renamed,added] else {
    print("FAIL stale organizer snapshot overwrites unrelated edit/add/delete");exit(1)
  }
  var changedFirst=first;changedFirst.name="Affected metadata changed"
  guard Organizer.mergingSpaceChanges(staged,expected:expected,latest:[changedFirst,other,deleted],affected:[first.id]) == nil else {
    print("FAIL affected metadata change must reject stale operation");exit(1)
  }
  print("PASS organizer merges latest unrelated inventory and rejects changed affected metadata")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='vane-organizer-merge-') as temporary:
    root=Path(temporary);swift=root/'probe.swift';binary=root/'probe'
    swift.write_text(source)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(swift),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
