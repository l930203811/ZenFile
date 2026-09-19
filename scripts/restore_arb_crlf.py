import io, os, glob

DIR = r'D:\Xiangmu\ZenFile-main\lib\l10n'
for p in sorted(glob.glob(os.path.join(DIR, 'app_*.arb'))):
    raw = io.open(p, 'rb').read()
    crlf = raw.count(b'\r\n')
    lf = raw.count(b'\n')
    if crlf == lf and crlf > 0:
        print(os.path.basename(p), 'already CRLF')
        continue
    # 先归一到 LF，再统一转 CRLF
    norm = raw.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    fixed = norm.replace(b'\n', b'\r\n')
    io.open(p, 'wb').write(fixed)
    print(os.path.basename(p), 'restored CRLF:', fixed.count(b'\r\n'))
