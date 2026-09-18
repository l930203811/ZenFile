import subprocess, io, os

REPO = r'D:\Xiangmu\ZenFile-main'
FILES = [
    'lib/l10n/app_ar.arb','lib/l10n/app_de.arb','lib/l10n/app_en.arb','lib/l10n/app_es.arb',
    'lib/l10n/app_fr.arb','lib/l10n/app_ja.arb','lib/l10n/app_ko.arb','lib/l10n/app_ru.arb',
    'lib/l10n/app_zh.arb','lib/l10n/app_zh_TW.arb',
    'lib/l10n/generated/app_localizations.dart',
    'lib/l10n/generated/app_localizations_ar.dart','lib/l10n/generated/app_localizations_de.dart',
    'lib/l10n/generated/app_localizations_en.dart','lib/l10n/generated/app_localizations_es.dart',
    'lib/l10n/generated/app_localizations_fr.dart','lib/l10n/generated/app_localizations_ja.dart',
    'lib/l10n/generated/app_localizations_ko.dart','lib/l10n/generated/app_localizations_ru.dart',
    'lib/l10n/generated/app_localizations_zh.dart',
    'lib/ui/screens/about_screen.dart','lib/ui/screens/network_connection_wizard_screen.dart',
    'lib/ui/screens/remote_explorer_screen.dart','lib/ui/widgets/zenfile_drawer.dart',
    'pubspec.yaml',
]


def counts(data):
    return data.count(b'\r\n'), data.count(b'\n')


bad = []
for f in FILES:
    head = subprocess.run(['git', 'show', f'HEAD:{f}'], cwd=REPO, capture_output=True)
    if head.returncode != 0:
        print('SKIP (not in HEAD):', f)
        continue
    cur = io.open(os.path.join(REPO, f), 'rb').read()
    hc, hn = counts(head.stdout)
    cc, cn = counts(cur)
    flag = ''
    if (hc > 0) != (cc > 0):
        flag = '  <<< EOL FLIPPED'
        bad.append(f)
    print(f'{f:52s} HEAD crlf={hc:5d} lf={hn:5d} | NOW crlf={cc:5d} lf={cn:5d}{flag}')

print()
print('EOL flipped files:', bad if bad else 'NONE')
