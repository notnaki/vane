"""Collect only positively bound private trace exports before native retirement."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import uuid

MAXIMUM_BYTES = 4194304
NAME = re.compile(r'^f17trace-([1-9][0-9]*)-([1-9][0-9]*)-(spell|continuation)-([0-9A-F-]{36})\.(trace|pending)$')
HEADER_KEYS = {'schema','kind','channel','case','sourceRevision','sourceRevisionProvenance','manifestDirectory','token','host','exportStage'}
HOST_KEYS = {'pid','start','path','processName','bundleIdentifier','testBundlePath'}
END_KEYS = {'schema','kind','channel','case'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def case_key(value):
    match = re.fullmatch(r'-\[(?:VaneTests\.)?([A-Za-z_]\w*) ([A-Za-z_]\w*)\]', value)
    if not match: raise ValueError('invalid raw XCTest case name')
    return 'VaneTests.' + match[1] + '/' + match[2]


def strict_json(data):
    def unique(pairs):
        result = {}
        for key,value in pairs:
            if key in result: raise ValueError('duplicate JSON key ' + key)
            result[key] = value
        return result
    return json.loads(data.decode('utf-8'), object_pairs_hook=unique,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('invalid JSON constant')))


def identity(info):
    return (info.st_dev,info.st_ino,info.st_mode,info.st_uid,info.st_nlink,info.st_size,info.st_mtime_ns,info.st_ctime_ns)


def validate_header(header, match, directory, token, records, bundle, source, allowed):
    assert isinstance(header,dict) and header.keys()==HEADER_KEYS, 'header keys changed'
    assert type(header['schema']) is int and header['schema']==1 and header['kind']=='F17_PRIVATE_TRACE'
    assert header['channel']==match[3] and header['sourceRevision']==source
    assert header['sourceRevisionProvenance']=='controller-verified-environment'
    assert header['manifestDirectory']==str(directory) and header['token']==token
    assert header['exportStage']=='after-fixture-assertions-and-AppKit-loop-join'
    assert case_key(header['case']) in allowed, 'foreign case'
    host=header['host'];assert isinstance(host,dict) and host.keys()==HOST_KEYS
    assert type(host['pid']) is int and type(host['start']) is int
    assert (host['pid'],host['start'])==(int(match[1]),int(match[2]))
    assert host['testBundlePath']==str(bundle)
    assert sum(host==record['host'] for record in records)==1, 'export is not bound to one validated primary host'


def validate_payload(raw, header):
    assert raw.endswith(b'\n'), 'export is not LF terminated'
    parts=raw.split(b'\n');assert len(parts)>=3
    end=strict_json(parts[-2]);assert isinstance(end,dict) and end.keys()==END_KEYS
    assert type(end['schema']) is int and end['schema']==1 and end['kind']=='F17_PRIVATE_TRACE_END'
    assert end['channel']==header['channel'] and end['case']==header['case'], 'end binding changed'
    body=b'\n'.join(parts[1:-2])+b'\n' if len(parts)>3 else b''
    text=body.decode('utf-8')
    if header['channel']=='spell':
        assert text and all(line.startswith('F17_SPELL ') for line in text.splitlines()), 'foreign spell payload'
    else:
        for line in text.splitlines():
            match=re.fullmatch(r'F17_CONTINUATION case=("(?:[^"\\]|\\.)*") phase=(\S+) uptime=([\d.]+) ([^\n]*)',line)
            assert match and strict_json(match[1].encode())==header['case'], 'continuation record/case mismatch or overflow'
            assert math.isfinite(float(match[3])), 'nonfinite continuation time'
    return body


def archive_bytes(audit, name, raw):
    path=audit/name;fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        offset=0
        while offset<len(raw):
            written=os.write(fd,raw[offset:]);assert written>0,'short archive write';offset+=written
        os.fsync(fd)
    finally:os.close(fd)
    assert path.read_bytes()==raw, 'archive verification failed'
    return name


def collect(directory, token, records, audit, bundle, source, allowed_cases, expected_files):
    """Archive first; remove a name only after complete positive header ownership."""
    directory,audit,bundle=Path(directory),Path(audit),Path(bundle)
    info=directory.lstat();assert stat.S_ISDIR(info.st_mode) and info.st_uid==os.geteuid() and stat.S_IMODE(info.st_mode)==0o700 and directory.resolve()==directory
    info=audit.lstat();assert stat.S_ISDIR(info.st_mode) and info.st_uid==os.geteuid() and stat.S_IMODE(info.st_mode)==0o700 and audit.resolve()==audit
    assert re.fullmatch(r'[0-9a-f]{40}',source) and re.fullmatch(r'[0-9a-f]{32}',token)
    assert records and all(r['schema']==1 and r['token']==token and r['host']['testBundlePath']==str(bundle) for r in records)
    allowed={case_key(c) for c in allowed_cases};expected=sorted((case_key(c),channel) for c,channel in expected_files)
    errors,exports=[],[];directory_fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        parent=identity(os.fstat(directory_fd));names=sorted(name for name in os.listdir(directory_fd) if name.startswith('f17trace-'))
        assert len(names)<=128, 'too many private trace exports'
        for index,name in enumerate(names):
            item={'name':name,'removed':False,'ownership_verified':False};exports.append(item);fd=None
            try:
                match=NAME.fullmatch(name);assert match,'unrecognized private export name'
                assert str(uuid.UUID(match[4])).upper()==match[4], 'noncanonical export UUID'
                assert any((r['host']['pid'],r['host']['start'])==(int(match[1]),int(match[2])) for r in records), 'foreign filename host'
                fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory_fd);before=os.fstat(fd)
                assert stat.S_ISREG(before.st_mode) and before.st_uid==os.geteuid() and stat.S_IMODE(before.st_mode)==0o600 and before.st_nlink==1 and before.st_size<=MAXIMUM_BYTES, 'export must be bounded private regular0600 single-link file'
                chunks=[];size=0
                while True:
                    chunk=os.read(fd,min(65536,MAXIMUM_BYTES+1-size))
                    if not chunk:break
                    chunks.append(chunk);size+=len(chunk);assert size<=MAXIMUM_BYTES,'export too large'
                raw=b''.join(chunks);assert len(raw)==before.st_size and identity(os.fstat(fd))==identity(before), 'export changed during read'
                archived=archive_bytes(audit,f'private-export-{index:03d}-{name}',raw)
                item.update(archive=archived,sha256=digest(raw),bytes=len(raw))
                assert b'\n' in raw, 'incomplete header'
                header=strict_json(raw.split(b'\n',1)[0]);validate_header(header,match,directory,token,records,bundle,source,allowed)
                item.update(ownership_verified=True,header=header)
                try:
                    body=validate_payload(raw,header);assert match[5]=='trace','unpublished pending export'
                    item.update(payload_complete=True,body_sha256=digest(body),body_bytes=len(body))
                except Exception as error:item['payload_complete']=False;errors.append(name+': payload '+repr(error))
                current=os.stat(name,dir_fd=directory_fd,follow_symlinks=False)
                # Directory mtime changes as names are removed; identity/ownership may not.
                now=os.fstat(directory_fd);assert (now.st_dev,now.st_ino,now.st_mode,now.st_uid)==parent[:4]
                path_info=directory.lstat();assert (path_info.st_dev,path_info.st_ino)==(now.st_dev,now.st_ino) and directory.resolve()==directory
                assert identity(current)==identity(before)==identity(os.fstat(fd)), 'export replaced before unlink'
                os.unlink(name,dir_fd=directory_fd);item['removed']=True
            except Exception as error:errors.append(name+': capture '+repr(error))
            finally:
                if fd is not None:os.close(fd)
    finally:os.close(directory_fd)
    actual=sorted((case_key(e['header']['case']),e['header']['channel']) for e in exports if e.get('payload_complete') and e['removed'])
    if actual!=expected:errors.append('published case/channel inventory differs from frozen expected exports')
    return {'exports':exports,'validation_errors':errors,'capture_complete':not errors,'stage':'after-completed-canonical-check_hosts-before-fresh-retirement','sourceRevision':source,'token':token,'manifestDirectory':str(directory),'no_console_fallback':True}
