import sys
p = sys.argv[1] + '/Sources/macprovider-cli/NativeMTPBenchCommand.swift'
s = open(p).read()
old = 'FileHandle.standardError.write("[lab-cell] rep=\\(rep) cell=\\(cell) at=\\(Date().timeIntervalSince1970)\\n".data(using: .utf8)!)'
assert s.count(old) == 1
s = s.replace(old, 'FileHandle.standardError.write("[lab-cell] rep=\\(rep) cell=\\(cell) at=\\(Date().timeIntervalSince1970) \\(LabStale.summary())\\n".data(using: .utf8)!)')
open(p, 'w').write(s)
print("patched p3 v2")
