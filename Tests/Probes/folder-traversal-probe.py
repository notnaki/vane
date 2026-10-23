from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[2]
def block(text,start):
 i=text.index(start); b=text.index('{',i); depth=1;j=b+1
 while depth:
  if text[j]=='{': depth+=1
  elif text[j]=='}': depth-=1
  j+=1
 return text[i:j]
f=(root/'Sources/Vane/Folders.swift').read_text()
s='import Foundation\nstruct LiveSource:Codable,Equatable,Sendable {}\n'+block(f,'struct Folder:')+'\n'+block(f,'struct Pins:')
s+='''
var a=Folder(name:"A"),b=Folder(name:"B");b.requiresAuthentication=true
var cyclic=Pins();cyclic.entries=[.init(row:.folder(a),parent:b.id),.init(row:.folder(b),parent:a.id),.init(row:.tab("inside"),parent:a.id)]
precondition(Pins.TraversalIndex(cyclic.entries).lockedRows(in:cyclic.entries,unlocked:[]).contains("inside"))
let folders = (0..<5000).map { Folder(name: "F\\($0)") }
var p = Pins()
for f in folders { p.entries.append(.init(row:.folder(f))); p.entries.append(.init(row:.tab(f.id.uuidString + "tab"),parent:f.id)) }
let before=Date(); let rows=p.visible; let elapsed=Date().timeIntervalSince(before)
print("folder rows=\\(rows.count), seconds=\\(elapsed)")
if elapsed > 0.25 { print("FAIL: shallow visible traversal rescans entire shape"); exit(1) }
'''
Path('/tmp/vane-task5-folder.swift').write_text(s)
r=subprocess.run(['swiftc','-O','/tmp/vane-task5-folder.swift','-o','/tmp/vane-task5-folder'],capture_output=True,text=True);print(r.stdout+r.stderr)
if r.returncode==0: subprocess.run(['/tmp/vane-task5-folder'])
