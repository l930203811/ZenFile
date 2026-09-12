#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""插入「保险箱帮助」页面所需的 l10n key。

铁律（与 add_remote_crypt_io_l10n.py 一致）：
- lib/l10n/app_*.arb 用 CRLF，lib/l10n/generated/*.dart 用 LF → 全程二进制读写。
- 按锚点（crypt_settings_title）插入，不重跑 gen-l10n
  （会覆盖手工合并的 L10nZh / L10nZhTw）。
- zh.dart 里锚点出现两次（L10nZh、L10nZhTw）：第一次用 zh，第二次用 zh_TW。
- 全部为**无占位符**的纯字符串 getter（dart 侧 `String get xxx => '...';`）。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARB_DIR = os.path.join(ROOT, 'lib', 'l10n')
GEN_DIR = os.path.join(ARB_DIR, 'generated')

KEYS = [
    'vault_help',
    'vault_help_title',
    'vault_help_intro',
    'vault_help_highlights',
    'vault_help_hl1_title', 'vault_help_hl1_desc',
    'vault_help_hl2_title', 'vault_help_hl2_desc',
    'vault_help_hl3_title', 'vault_help_hl3_desc',
    'vault_help_basics',
    'vault_help_b1_title', 'vault_help_b1_desc',
    'vault_help_b2_title', 'vault_help_b2_desc',
    'vault_help_b3_title', 'vault_help_b3_desc',
    'vault_help_b4_title', 'vault_help_b4_desc',
    'vault_help_b5_title', 'vault_help_b5_desc',
    'vault_help_compat',
    'vault_help_c1_title', 'vault_help_c1_desc',
    'vault_help_c2_title', 'vault_help_c2_desc',
    'vault_help_c3_title', 'vault_help_c3_desc',
    'vault_help_inplace',
    'vault_help_inplace_intro',
    'vault_help_ip1_title', 'vault_help_ip1_desc',
    'vault_help_ip2_title', 'vault_help_ip2_desc',
    'vault_help_ip3_title', 'vault_help_ip3_desc',
    'vault_help_ip4_title', 'vault_help_ip4_desc',
    'vault_help_notice',
    'vault_help_n1', 'vault_help_n2', 'vault_help_n3',
]

ZH = {
    'vault_help': '帮助',
    'vault_help_title': '保险箱帮助',
    'vault_help_intro': '保险箱采用与 rclone 相同的 crypt 加密格式，加解密全部在本机完成，密钥不会离开本机。',
    'vault_help_highlights': '功能亮点',
    'vault_help_hl1_title': '零知识加密',
    'vault_help_hl1_desc': '主密码与加盐仅保存在本机，云服务与任何第三方都无法解密你的文件。',
    'vault_help_hl2_title': '兼容 rclone 与 OpenList',
    'vault_help_hl2_desc': '使用相同的 crypt 格式，电脑上的 rclone 可直接解密同一批文件。',
    'vault_help_hl3_title': '多套密码 + 远程直读',
    'vault_help_hl3_desc': '可为不同目录绑定不同密码档案；远程密文目录无需整体下载即可解密浏览与播放。',
    'vault_help_basics': '基本操作',
    'vault_help_b1_title': '① 先配置主密码',
    'vault_help_b1_desc': '在「密码配置」中设置主密码与加盐并牢记，它与保险箱解锁密码相互独立。',
    'vault_help_b2_title': '② 加密文件',
    'vault_help_b2_desc': '在浏览页选择文件后点击加密，再选择「原地加密」或「沙盒加密」。',
    'vault_help_b3_title': '③ 查看与打开',
    'vault_help_b3_desc': '加密条目集中在保险箱中列出，点击会自动临时解密后预览。',
    'vault_help_b4_title': '④ 解密还原',
    'vault_help_b4_desc': '选中条目点击解密，即可还原为普通文件并放回原位置。',
    'vault_help_b5_title': '⑤ 备份与恢复',
    'vault_help_b5_desc': '通过「备份/恢复」导出含加密配置的备份，卸载应用前务必先导出。',
    'vault_help_compat': '兼容性',
    'vault_help_c1_title': '加密格式',
    'vault_help_c1_desc': '内容为 XSalsa20-Poly1305，文件名经 EME 加密后以 base32/base64 编码，可带 .bin 后缀。',
    'vault_help_c2_title': '网盘与同步',
    'vault_help_c2_desc': '密文可被任意网盘或同步工具正常同步，服务端只能看到密文，不会泄露真实文件名。',
    'vault_help_c3_title': '已知限制',
    'vault_help_c3_desc': '加密后文件名会显著变长，超长文件名可能失败；请在本应用内重命名，直接改密文名会导致无法解密。',
    'vault_help_inplace': '原地加密',
    'vault_help_inplace_intro': '原地加密会把文件「就地」加密：内容替换为密文、文件名替换为密文名，文件仍留在原来的文件夹中，不会进入保险箱私有目录。',
    'vault_help_ip1_title': '与原目录的关系',
    'vault_help_ip1_desc': '文件位置与目录结构保持不变，浏览页会给已加密文件加上🔐徽标。',
    'vault_help_ip2_title': '其它应用看到什么',
    'vault_help_ip2_desc': '其它文件管理器与播放器只能看到无意义的密文文件名且无法打开，这正是保护效果。',
    'vault_help_ip3_title': '适合的场景',
    'vault_help_ip3_desc': '需要保留原目录结构，并让第三方网盘继续同步这些文件的场景。',
    'vault_help_ip4_title': '风险与建议',
    'vault_help_ip4_desc': '加密会直接替换原文件，中断可能留下残留文件；重要文件请先备份，解密时目标目录需有写入权限。',
    'vault_help_notice': '注意事项',
    'vault_help_n1': '已用于加密文件的密码与加盐不可修改，若需更换请新建一份加密配置。',
    'vault_help_n2': '沙盒加密的文件存放在应用私有目录，卸载应用会一并清除。',
    'vault_help_n3': '忘记主密码将无法恢复任何已加密文件，请务必导出备份并妥善保存。',
}

ZH_TW = {
    'vault_help': '說明',
    'vault_help_title': '保險箱說明',
    'vault_help_intro': '保險箱採用與 rclone 相同的 crypt 加密格式，加解密全部在本機完成，金鑰不會離開本機。',
    'vault_help_highlights': '功能亮點',
    'vault_help_hl1_title': '零知識加密',
    'vault_help_hl1_desc': '主密碼與加鹽僅儲存在本機，雲端服務與任何第三方都無法解密你的檔案。',
    'vault_help_hl2_title': '相容 rclone 與 OpenList',
    'vault_help_hl2_desc': '使用相同的 crypt 格式，電腦上的 rclone 可直接解密同一批檔案。',
    'vault_help_hl3_title': '多組密碼 + 遠端直讀',
    'vault_help_hl3_desc': '可為不同目錄綁定不同密碼設定；遠端密文目錄無須整包下載即可解密瀏覽與播放。',
    'vault_help_basics': '基本操作',
    'vault_help_b1_title': '① 先設定主密碼',
    'vault_help_b1_desc': '在「密碼設定」中設定主密碼與加鹽並牢記，它與保險箱解鎖密碼彼此獨立。',
    'vault_help_b2_title': '② 加密檔案',
    'vault_help_b2_desc': '在瀏覽頁選取檔案後點選加密，再選擇「原地加密」或「沙盒加密」。',
    'vault_help_b3_title': '③ 檢視與開啟',
    'vault_help_b3_desc': '加密項目會集中在保險箱中列出，點選後會自動暫時解密並預覽。',
    'vault_help_b4_title': '④ 解密還原',
    'vault_help_b4_desc': '選取項目後點選解密，即可還原為一般檔案並放回原位置。',
    'vault_help_b5_title': '⑤ 備份與還原',
    'vault_help_b5_desc': '透過「備份/還原」匯出含加密設定的備份，解除安裝前務必先匯出。',
    'vault_help_compat': '相容性',
    'vault_help_c1_title': '加密格式',
    'vault_help_c1_desc': '內容為 XSalsa20-Poly1305，檔名經 EME 加密後以 base32/base64 編碼，可帶 .bin 後綴。',
    'vault_help_c2_title': '雲端與同步',
    'vault_help_c2_desc': '密文可由任意雲端或同步工具正常同步，伺服器只會看到密文，不會洩漏真實檔名。',
    'vault_help_c3_title': '已知限制',
    'vault_help_c3_desc': '加密後檔名會明顯變長，過長檔名可能失敗；請在本應用程式內重新命名，直接改密文名將導致無法解密。',
    'vault_help_inplace': '原地加密',
    'vault_help_inplace_intro': '原地加密會把檔案「就地」加密：內容替換為密文、檔名替換為密文名，檔案仍留在原本的資料夾中，不會進入保險箱私有目錄。',
    'vault_help_ip1_title': '與原目錄的關係',
    'vault_help_ip1_desc': '檔案位置與目錄結構維持不變，瀏覽頁會為已加密檔案加上🔐徽標。',
    'vault_help_ip2_title': '其他應用程式看到什麼',
    'vault_help_ip2_desc': '其他檔案管理器與播放器只會看到無意義的密文檔名且無法開啟，這正是保護效果。',
    'vault_help_ip3_title': '適合的情境',
    'vault_help_ip3_desc': '需要保留原目錄結構，並讓第三方雲端繼續同步這些檔案的情境。',
    'vault_help_ip4_title': '風險與建議',
    'vault_help_ip4_desc': '加密會直接取代原檔，中斷可能留下殘檔；重要檔案請先備份，解密時目標目錄需有寫入權限。',
    'vault_help_notice': '注意事項',
    'vault_help_n1': '已用於加密檔案的密碼與加鹽不可修改，若需更換請新增一組加密設定。',
    'vault_help_n2': '沙盒加密的檔案存放於應用程式私有目錄，解除安裝時會一併清除。',
    'vault_help_n3': '忘記主密碼將無法還原任何已加密檔案，請務必匯出備份並妥善保存。',
}

EN = {
    'vault_help': 'Help',
    'vault_help_title': 'Vault Help',
    'vault_help_intro': 'The vault uses the same crypt format as rclone. Encryption and decryption happen entirely on this device, and the key never leaves it.',
    'vault_help_highlights': 'Highlights',
    'vault_help_hl1_title': 'Zero-knowledge encryption',
    'vault_help_hl1_desc': 'The master password and salt stay on this device only, so no cloud service or third party can decrypt your files.',
    'vault_help_hl2_title': 'Works with rclone and OpenList',
    'vault_help_hl2_desc': 'The same crypt format is used, so rclone on a computer can decrypt exactly the same files.',
    'vault_help_hl3_title': 'Multiple passwords, remote reading',
    'vault_help_hl3_desc': 'Bind a different password profile to each folder, and browse or stream remote folders without downloading them first.',
    'vault_help_basics': 'Basic operations',
    'vault_help_b1_title': '1. Set the master password first',
    'vault_help_b1_desc': 'Configure the master password and salt in Password profiles and memorise them; they are independent of the vault unlock password.',
    'vault_help_b2_title': '2. Encrypt files',
    'vault_help_b2_desc': 'Select files in the browser, tap Encrypt, then choose in-place or sandbox encryption.',
    'vault_help_b3_title': '3. View and open',
    'vault_help_b3_desc': 'Encrypted items are listed in the vault; tapping one decrypts it temporarily for preview.',
    'vault_help_b4_title': '4. Decrypt',
    'vault_help_b4_desc': 'Select an item and tap Decrypt to restore it as a normal file in its original place.',
    'vault_help_b5_title': '5. Back up and restore',
    'vault_help_b5_desc': 'Export a backup containing your encryption profiles from Backup / Restore before uninstalling the app.',
    'vault_help_compat': 'Compatibility',
    'vault_help_c1_title': 'Encryption format',
    'vault_help_c1_desc': 'Content uses XSalsa20-Poly1305; names are EME-encrypted and encoded as base32/base64, optionally with a .bin suffix.',
    'vault_help_c2_title': 'Cloud drives and sync',
    'vault_help_c2_desc': 'Ciphertext syncs fine with any drive or sync tool; the server only sees ciphertext and never the real file names.',
    'vault_help_c3_title': 'Known limits',
    'vault_help_c3_desc': 'Encrypted names are much longer, so very long names may fail; rename only inside this app, since editing a ciphertext name makes it undecryptable.',
    'vault_help_inplace': 'In-place encryption',
    'vault_help_inplace_intro': 'In-place encryption encrypts files where they are: content and name are replaced by ciphertext, and the file stays in its original folder instead of moving into the private vault directory.',
    'vault_help_ip1_title': 'Relation to the original folder',
    'vault_help_ip1_desc': 'Location and folder structure stay unchanged; encrypted files get a lock badge in the browser.',
    'vault_help_ip2_title': 'What other apps see',
    'vault_help_ip2_desc': 'Other file managers and players only see meaningless ciphertext names and cannot open them, which is exactly the protection.',
    'vault_help_ip3_title': 'When to use it',
    'vault_help_ip3_desc': 'When you want to keep the folder structure and let third-party cloud apps keep syncing those files.',
    'vault_help_ip4_title': 'Risks and advice',
    'vault_help_ip4_desc': 'Encryption replaces the original file directly, so an interruption may leave partial files. Back up first and make sure the target folder is writable when decrypting.',
    'vault_help_notice': 'Notes',
    'vault_help_n1': 'The password and salt already used for encrypted files cannot be changed; create a new profile if you need a different one.',
    'vault_help_n2': 'Sandbox-encrypted files live in the private app directory and are removed when the app is uninstalled.',
    'vault_help_n3': 'If the master password is forgotten, no encrypted file can be recovered, so always export a backup and keep it safe.',
}

JA = {
    'vault_help': 'ヘルプ',
    'vault_help_title': '金庫ヘルプ',
    'vault_help_intro': '金庫は rclone と同じ crypt 形式を採用しています。暗号化と復号はすべて端末内で行われ、鍵が外に出ることはありません。',
    'vault_help_highlights': '主な特長',
    'vault_help_hl1_title': 'ゼロ知識暗号',
    'vault_help_hl1_desc': 'マスターパスワードとソルトは端末内のみに保存され、クラウド事業者を含む第三者は復号できません。',
    'vault_help_hl2_title': 'rclone / OpenList 互換',
    'vault_help_hl2_desc': '同じ crypt 形式のため、PC の rclone でも同じファイルを復号できます。',
    'vault_help_hl3_title': '複数パスワードとリモート直読',
    'vault_help_hl3_desc': 'フォルダごとに異なるパスワード設定を割り当て可能。リモートの暗号化フォルダも丸ごとダウンロードせずに閲覧・再生できます。',
    'vault_help_basics': '基本操作',
    'vault_help_b1_title': '① まずマスターパスワードを設定',
    'vault_help_b1_desc': '「パスワード設定」でマスターパスワードとソルトを設定し、必ず控えてください。金庫のロック解除パスワードとは別物です。',
    'vault_help_b2_title': '② ファイルを暗号化',
    'vault_help_b2_desc': 'ブラウザでファイルを選んで暗号化をタップし、「その場で暗号化」か「サンドボックス暗号化」を選びます。',
    'vault_help_b3_title': '③ 表示とオープン',
    'vault_help_b3_desc': '暗号化した項目は金庫に一覧表示され、タップすると一時的に復号してプレビューします。',
    'vault_help_b4_title': '④ 復号して元に戻す',
    'vault_help_b4_desc': '項目を選んで復号すると、通常のファイルとして元の場所へ戻ります。',
    'vault_help_b5_title': '⑤ バックアップと復元',
    'vault_help_b5_desc': '「バックアップ/復元」から暗号化設定を含むバックアップを書き出してください。アンインストール前に必ず実行してください。',
    'vault_help_compat': '互換性',
    'vault_help_c1_title': '暗号化形式',
    'vault_help_c1_desc': '本文は XSalsa20-Poly1305、ファイル名は EME 暗号化後に base32/base64 で符号化され、.bin を付けることもできます。',
    'vault_help_c2_title': 'クラウドと同期',
    'vault_help_c2_desc': '暗号文はどのクラウドや同期ツールでもそのまま同期できます。サーバーには暗号文しか見えず、実ファイル名は漏れません。',
    'vault_help_c3_title': '既知の制限',
    'vault_help_c3_desc': '暗号化するとファイル名が大幅に長くなります。長すぎる名前は失敗する場合があります。名前の変更は本アプリ内で行い、暗号文の名前を直接書き換えると復号できなくなります。',
    'vault_help_inplace': 'その場で暗号化',
    'vault_help_inplace_intro': 'その場で暗号化はファイルを元の場所で暗号化します。中身とファイル名が暗号文に置き換わり、ファイルは元のフォルダに残ったまま金庫の専用ディレクトリには移動しません。',
    'vault_help_ip1_title': '元フォルダとの関係',
    'vault_help_ip1_desc': '場所とフォルダ構成は変わらず、ブラウザでは暗号化済みファイルに🔐マークが付きます。',
    'vault_help_ip2_title': '他のアプリからはどう見えるか',
    'vault_help_ip2_desc': '他のファイル管理アプリやプレイヤーには意味のない暗号名が見えるだけで開けません。これが保護の仕組みです。',
    'vault_help_ip3_title': '向いている場面',
    'vault_help_ip3_desc': 'フォルダ構成を保ちながら、サードパーティのクラウドアプリに同期させ続けたい場合に最適です。',
    'vault_help_ip4_title': 'リスクと注意点',
    'vault_help_ip4_desc': '暗号化は元ファイルを直接置き換えるため、中断すると中途半端なファイルが残ることがあります。重要なファイルは事前バックアップを、復号時は書き込み権限を確認してください。',
    'vault_help_notice': 'ご注意',
    'vault_help_n1': '暗号化に使用したパスワードとソルトは変更できません。変更したい場合は新しい設定を作成してください。',
    'vault_help_n2': 'サンドボックス暗号化のファイルはアプリ専用ディレクトリにあり、アンインストールすると消去されます。',
    'vault_help_n3': 'マスターパスワードを忘れると暗号化ファイルは復元できません。必ずバックアップを書き出して保管してください。',
}

KO = {
    'vault_help': '도움말',
    'vault_help_title': '금고 도움말',
    'vault_help_intro': '금고는 rclone과 동일한 crypt 형식을 사용합니다. 암호화와 복호화는 모두 기기에서 이루어지며 키는 기기 밖으로 나가지 않습니다.',
    'vault_help_highlights': '주요 기능',
    'vault_help_hl1_title': '제로 지식 암호화',
    'vault_help_hl1_desc': '마스터 비밀번호와 솔트는 기기에만 저장되므로 클라우드 서비스나 제3자는 파일을 복호화할 수 없습니다.',
    'vault_help_hl2_title': 'rclone · OpenList 호환',
    'vault_help_hl2_desc': '동일한 crypt 형식을 사용하므로 PC의 rclone으로 같은 파일을 그대로 복호화할 수 있습니다.',
    'vault_help_hl3_title': '여러 비밀번호와 원격 직접 읽기',
    'vault_help_hl3_desc': '폴더마다 다른 비밀번호 프로필을 지정할 수 있고, 원격 암호 폴더는 전체를 내려받지 않고도 탐색·재생할 수 있습니다.',
    'vault_help_basics': '기본 조작',
    'vault_help_b1_title': '① 마스터 비밀번호 먼저 설정',
    'vault_help_b1_desc': '「비밀번호 설정」에서 마스터 비밀번호와 솔트를 설정하고 반드시 기억하세요. 금고 잠금 해제 비밀번호와는 별개입니다.',
    'vault_help_b2_title': '② 파일 암호화',
    'vault_help_b2_desc': '브라우저에서 파일을 선택한 뒤 암호화를 누르고 「원위치 암호화」 또는 「샌드박스 암호화」를 고릅니다.',
    'vault_help_b3_title': '③ 보기와 열기',
    'vault_help_b3_desc': '암호화된 항목은 금고에 목록으로 표시되며, 누르면 임시로 복호화되어 미리보기가 열립니다.',
    'vault_help_b4_title': '④ 복호화하여 복원',
    'vault_help_b4_desc': '항목을 선택하고 복호화하면 일반 파일로 원래 위치에 복원됩니다.',
    'vault_help_b5_title': '⑤ 백업과 복원',
    'vault_help_b5_desc': '「백업/복원」에서 암호화 설정이 포함된 백업을 내보내세요. 앱을 삭제하기 전에 반드시 실행하세요.',
    'vault_help_compat': '호환성',
    'vault_help_c1_title': '암호화 형식',
    'vault_help_c1_desc': '내용은 XSalsa20-Poly1305, 파일 이름은 EME 암호화 후 base32/base64로 인코딩되며 .bin 접미사를 붙일 수 있습니다.',
    'vault_help_c2_title': '클라우드와 동기화',
    'vault_help_c2_desc': '암호문은 어떤 클라우드나 동기화 도구로도 그대로 동기화됩니다. 서버에는 암호문만 보이며 실제 파일 이름은 노출되지 않습니다.',
    'vault_help_c3_title': '알려진 제한',
    'vault_help_c3_desc': '암호화하면 파일 이름이 훨씬 길어져 너무 긴 이름은 실패할 수 있습니다. 이름 변경은 반드시 이 앱에서 하세요. 암호문 이름을 직접 고치면 복호화할 수 없습니다.',
    'vault_help_inplace': '원위치 암호화',
    'vault_help_inplace_intro': '원위치 암호화는 파일을 있던 자리에서 암호화합니다. 내용과 파일 이름이 암호문으로 바뀌고, 파일은 원래 폴더에 그대로 남아 금고 전용 디렉터리로 이동하지 않습니다.',
    'vault_help_ip1_title': '원본 폴더와의 관계',
    'vault_help_ip1_desc': '위치와 폴더 구조는 그대로이며, 브라우저에서는 암호화된 파일에 🔐 배지가 표시됩니다.',
    'vault_help_ip2_title': '다른 앱에서 보이는 모습',
    'vault_help_ip2_desc': '다른 파일 관리자나 플레이어에는 의미 없는 암호문 이름만 보이고 열 수 없습니다. 이것이 바로 보호 효과입니다.',
    'vault_help_ip3_title': '적합한 상황',
    'vault_help_ip3_desc': '폴더 구조를 유지하면서 서드파티 클라우드 앱이 계속 동기화하도록 하고 싶을 때 적합합니다.',
    'vault_help_ip4_title': '위험과 권장 사항',
    'vault_help_ip4_desc': '암호화는 원본 파일을 직접 바꾸므로 중단되면 일부 파일이 남을 수 있습니다. 중요한 파일은 미리 백업하고, 복호화할 때는 대상 폴더에 쓰기 권한이 있는지 확인하세요.',
    'vault_help_notice': '주의 사항',
    'vault_help_n1': '이미 암호화에 사용한 비밀번호와 솔트는 변경할 수 없습니다. 바꾸려면 새 프로필을 만드세요.',
    'vault_help_n2': '샌드박스 암호화 파일은 앱 전용 디렉터리에 저장되며 앱을 삭제하면 함께 지워집니다.',
    'vault_help_n3': '마스터 비밀번호를 잊으면 어떤 암호화 파일도 복구할 수 없습니다. 반드시 백업을 내보내어 보관하세요.',
}

DE = {
    'vault_help': 'Hilfe',
    'vault_help_title': 'Tresor-Hilfe',
    'vault_help_intro': 'Der Tresor nutzt dasselbe crypt-Format wie rclone. Ver- und Entschlüsselung erfolgen ausschließlich auf diesem Gerät, der Schlüssel verlässt es nie.',
    'vault_help_highlights': 'Funktions-Highlights',
    'vault_help_hl1_title': 'Verschlüsselung ohne Wissen Dritter',
    'vault_help_hl1_desc': 'Hauptpasswort und Salt bleiben nur auf diesem Gerät, kein Cloud-Dienst und kein Dritter kann deine Dateien entschlüsseln.',
    'vault_help_hl2_title': 'Kompatibel mit rclone und OpenList',
    'vault_help_hl2_desc': 'Es wird dasselbe crypt-Format verwendet, daher kann rclone am Computer dieselben Dateien entschlüsseln.',
    'vault_help_hl3_title': 'Mehrere Passwörter, Direktzugriff',
    'vault_help_hl3_desc': 'Pro Ordner kann ein eigenes Passwortprofil gebunden werden; entfernte Verzeichnisse lassen sich ohne kompletten Download durchsuchen und abspielen.',
    'vault_help_basics': 'Grundlegende Bedienung',
    'vault_help_b1_title': '1. Zuerst Hauptpasswort festlegen',
    'vault_help_b1_desc': 'Lege das Hauptpasswort und das Salt unter „Passwortprofile“ fest und merke sie dir; sie sind unabhängig vom Tresor-Sperrcode.',
    'vault_help_b2_title': '2. Dateien verschlüsseln',
    'vault_help_b2_desc': 'Dateien im Browser auswählen, auf Verschlüsseln tippen und „Direkt am Ort“ oder „Sandbox“ wählen.',
    'vault_help_b3_title': '3. Ansehen und öffnen',
    'vault_help_b3_desc': 'Verschlüsselte Einträge werden im Tresor gelistet; antippen entschlüsselt sie temporär für die Vorschau.',
    'vault_help_b4_title': '4. Entschlüsseln',
    'vault_help_b4_desc': 'Eintrag auswählen und Entschlüsseln tippen, um die Datei als normale Datei an ihren Ursprungsort zurückzuführen.',
    'vault_help_b5_title': '5. Sichern und wiederherstellen',
    'vault_help_b5_desc': 'Exportiere unter „Sichern/Wiederherstellen“ ein Backup mit deinen Verschlüsselungsprofilen, bevor du die App deinstallierst.',
    'vault_help_compat': 'Kompatibilität',
    'vault_help_c1_title': 'Verschlüsselungsformat',
    'vault_help_c1_desc': 'Inhalte nutzen XSalsa20-Poly1305; Namen werden per EME verschlüsselt und base32/base64 kodiert, optional mit der Endung .bin.',
    'vault_help_c2_title': 'Cloud und Synchronisation',
    'vault_help_c2_desc': 'Der Schlüsseltext lässt sich mit jedem Speicher oder Sync-Tool synchronisieren; der Server sieht nur Chiffre, nie die echten Dateinamen.',
    'vault_help_c3_title': 'Bekannte Grenzen',
    'vault_help_c3_desc': 'Verschlüsselte Namen sind deutlich länger, sehr lange Namen können fehlschlagen. Umbenennen nur in dieser App, sonst ist die Datei nicht mehr entschlüsselbar.',
    'vault_help_inplace': 'Direkt am Ort verschlüsseln',
    'vault_help_inplace_intro': 'Beim Verschlüsseln am Ort bleiben die Dateien im ursprünglichen Ordner: Inhalt und Name werden durch Chiffre ersetzt, die Datei wandert nicht in das private Tresorverzeichnis.',
    'vault_help_ip1_title': 'Verhältnis zum Ursprungsordner',
    'vault_help_ip1_desc': 'Ort und Ordnerstruktur bleiben unverändert; verschlüsselte Dateien erhalten im Browser ein Schloss-Symbol.',
    'vault_help_ip2_title': 'Was andere Apps sehen',
    'vault_help_ip2_desc': 'Andere Dateimanager und Player sehen nur bedeutungslose Chiffrenamen und können die Dateien nicht öffnen, genau das ist der Schutz.',
    'vault_help_ip3_title': 'Wann sinnvoll',
    'vault_help_ip3_desc': 'Wenn die Ordnerstruktur erhalten bleiben und Cloud-Apps von Drittanbietern diese Dateien weiter synchronisieren sollen.',
    'vault_help_ip4_title': 'Risiken und Empfehlung',
    'vault_help_ip4_desc': 'Die Verschlüsselung ersetzt die Originaldatei direkt, ein Abbruch kann Reste hinterlassen. Sichere Wichtiges vorher und prüfe beim Entschlüsseln die Schreibrechte.',
    'vault_help_notice': 'Hinweise',
    'vault_help_n1': 'Passwort und Salt bereits verschlüsselter Dateien sind nicht änderbar; erstelle bei Bedarf ein neues Profil.',
    'vault_help_n2': 'In der Sandbox verschlüsselte Dateien liegen im privaten App-Verzeichnis und werden beim Deinstallieren gelöscht.',
    'vault_help_n3': 'Bei vergessenem Hauptpasswort ist keine verschlüsselte Datei mehr rettbar, exportiere daher immer ein Backup.',
}

ES = {
    'vault_help': 'Ayuda',
    'vault_help_title': 'Ayuda de la caja fuerte',
    'vault_help_intro': 'La caja fuerte usa el mismo formato crypt que rclone. El cifrado y descifrado ocurren por completo en el dispositivo y la clave nunca sale de él.',
    'vault_help_highlights': 'Funciones destacadas',
    'vault_help_hl1_title': 'Cifrado de conocimiento cero',
    'vault_help_hl1_desc': 'La contraseña maestra y la sal solo se guardan en el dispositivo, por lo que ningún servicio ni tercero puede descifrar tus archivos.',
    'vault_help_hl2_title': 'Compatible con rclone y OpenList',
    'vault_help_hl2_desc': 'Se usa el mismo formato crypt, así que rclone en el ordenador puede descifrar exactamente los mismos archivos.',
    'vault_help_hl3_title': 'Varias contraseñas y lectura remota',
    'vault_help_hl3_desc': 'Puedes asignar un perfil de contraseña distinto a cada carpeta y explorar o reproducir carpetas cifradas remotas sin descargarlas enteras.',
    'vault_help_basics': 'Operaciones básicas',
    'vault_help_b1_title': '1. Configura primero la contraseña maestra',
    'vault_help_b1_desc': 'Define la contraseña maestra y la sal en «Perfiles de contraseña» y memorízalas; son independientes del código de desbloqueo.',
    'vault_help_b2_title': '2. Cifrar archivos',
    'vault_help_b2_desc': 'Selecciona archivos en el navegador, pulsa Cifrar y elige cifrado en el lugar o en zona aislada.',
    'vault_help_b3_title': '3. Ver y abrir',
    'vault_help_b3_desc': 'Los elementos cifrados se listan en la caja fuerte; al pulsarlos se descifran temporalmente para la vista previa.',
    'vault_help_b4_title': '4. Descifrar',
    'vault_help_b4_desc': 'Selecciona un elemento y pulsa Descifrar para restaurarlo como archivo normal en su ubicación original.',
    'vault_help_b5_title': '5. Copia y restauración',
    'vault_help_b5_desc': 'Exporta desde «Copia/Restaurar» una copia que incluya tus perfiles de cifrado antes de desinstalar la app.',
    'vault_help_compat': 'Compatibilidad',
    'vault_help_c1_title': 'Formato de cifrado',
    'vault_help_c1_desc': 'El contenido usa XSalsa20-Poly1305; los nombres se cifran con EME y se codifican en base32/base64, opcionalmente con sufijo .bin.',
    'vault_help_c2_title': 'Nube y sincronización',
    'vault_help_c2_desc': 'El texto cifrado se sincroniza con cualquier nube o herramienta; el servidor solo ve cifrado y nunca los nombres reales.',
    'vault_help_c3_title': 'Límites conocidos',
    'vault_help_c3_desc': 'Los nombres cifrados son mucho más largos y los muy largos pueden fallar; renombra solo desde la app, editar el nombre cifrado lo hace indescifrable.',
    'vault_help_inplace': 'Cifrado en el lugar',
    'vault_help_inplace_intro': 'El cifrado en el lugar cifra los archivos donde están: contenido y nombre se sustituyen por texto cifrado y el archivo permanece en su carpeta original, sin entrar en el directorio privado de la caja fuerte.',
    'vault_help_ip1_title': 'Relación con la carpeta original',
    'vault_help_ip1_desc': 'La ubicación y la estructura de carpetas no cambian; los archivos cifrados muestran un icono de candado en el navegador.',
    'vault_help_ip2_title': 'Qué ven otras aplicaciones',
    'vault_help_ip2_desc': 'Otros gestores y reproductores solo ven nombres cifrados sin sentido y no pueden abrirlos, esa es precisamente la protección.',
    'vault_help_ip3_title': 'Cuándo conviene',
    'vault_help_ip3_desc': 'Cuando quieres conservar la estructura de carpetas y que las apps de nube de terceros sigan sincronizando esos archivos.',
    'vault_help_ip4_title': 'Riesgos y consejos',
    'vault_help_ip4_desc': 'El cifrado sustituye el archivo original directamente y una interrupción puede dejar restos. Haz copia antes y comprueba los permisos de escritura al descifrar.',
    'vault_help_notice': 'Avisos',
    'vault_help_n1': 'La contraseña y la sal ya usadas para cifrar no se pueden cambiar; crea un perfil nuevo si necesitas otra.',
    'vault_help_n2': 'Los archivos cifrados en zona aislada están en el directorio privado de la app y se borran al desinstalarla.',
    'vault_help_n3': 'Si olvidas la contraseña maestra ningún archivo cifrado podrá recuperarse, exporta siempre una copia de seguridad.',
}

FR = {
    'vault_help': 'Aide',
    'vault_help_title': 'Aide du coffre-fort',
    'vault_help_intro': 'Le coffre utilise le même format crypt que rclone. Le chiffrement et le déchiffrement ont lieu entièrement sur l appareil et la clé n en sort jamais.',
    'vault_help_highlights': 'Points forts',
    'vault_help_hl1_title': 'Chiffrement zéro connaissance',
    'vault_help_hl1_desc': 'Le mot de passe principal et le sel restent sur l appareil : aucun service cloud ni tiers ne peut déchiffrer vos fichiers.',
    'vault_help_hl2_title': 'Compatible rclone et OpenList',
    'vault_help_hl2_desc': 'Le format crypt est identique, rclone sur ordinateur peut donc déchiffrer exactement les mêmes fichiers.',
    'vault_help_hl3_title': 'Plusieurs mots de passe, lecture à distance',
    'vault_help_hl3_desc': 'Associez un profil différent à chaque dossier et parcourez ou lisez les dossiers chiffrés distants sans tout télécharger.',
    'vault_help_basics': 'Opérations de base',
    'vault_help_b1_title': '1. Définir d abord le mot de passe principal',
    'vault_help_b1_desc': 'Configurez le mot de passe principal et le sel dans « Profils de mot de passe » et retenez-les : ils sont indépendants du code de déverrouillage.',
    'vault_help_b2_title': '2. Chiffrer des fichiers',
    'vault_help_b2_desc': 'Sélectionnez les fichiers dans le navigateur, touchez Chiffrer, puis choisissez chiffrement sur place ou en bac à sable.',
    'vault_help_b3_title': '3. Consulter et ouvrir',
    'vault_help_b3_desc': 'Les éléments chiffrés sont listés dans le coffre ; les toucher les déchiffre temporairement pour l aperçu.',
    'vault_help_b4_title': '4. Déchiffrer',
    'vault_help_b4_desc': 'Sélectionnez un élément et touchez Déchiffrer pour le restaurer en fichier normal à son emplacement d origine.',
    'vault_help_b5_title': '5. Sauvegarder et restaurer',
    'vault_help_b5_desc': 'Exportez depuis « Sauvegarde / Restauration » une sauvegarde contenant vos profils avant de désinstaller l application.',
    'vault_help_compat': 'Compatibilité',
    'vault_help_c1_title': 'Format de chiffrement',
    'vault_help_c1_desc': 'Le contenu utilise XSalsa20-Poly1305 ; les noms sont chiffrés par EME puis encodés en base32/base64, avec suffixe .bin facultatif.',
    'vault_help_c2_title': 'Cloud et synchronisation',
    'vault_help_c2_desc': 'Le texte chiffré se synchronise avec n importe quel cloud ou outil ; le serveur ne voit que du chiffré, jamais les vrais noms.',
    'vault_help_c3_title': 'Limites connues',
    'vault_help_c3_desc': 'Les noms chiffrés sont bien plus longs et les noms très longs peuvent échouer ; renommez uniquement dans l application, modifier le nom chiffré le rend indéchiffrable.',
    'vault_help_inplace': 'Chiffrement sur place',
    'vault_help_inplace_intro': 'Le chiffrement sur place chiffre les fichiers là où ils se trouvent : contenu et nom deviennent du texte chiffré et le fichier reste dans son dossier d origine au lieu d entrer dans le répertoire privé du coffre.',
    'vault_help_ip1_title': 'Lien avec le dossier d origine',
    'vault_help_ip1_desc': 'L emplacement et la structure des dossiers ne changent pas ; les fichiers chiffrés reçoivent un badge cadenas dans le navigateur.',
    'vault_help_ip2_title': 'Ce que voient les autres applications',
    'vault_help_ip2_desc': 'Les autres gestionnaires et lecteurs ne voient que des noms chiffrés sans signification et ne peuvent pas les ouvrir : c est précisément la protection.',
    'vault_help_ip3_title': 'Quand l utiliser',
    'vault_help_ip3_desc': 'Pour conserver la structure des dossiers tout en laissant des applications cloud tierces continuer à synchroniser ces fichiers.',
    'vault_help_ip4_title': 'Risques et conseils',
    'vault_help_ip4_desc': 'Le chiffrement remplace directement le fichier d origine, une interruption peut laisser des restes. Sauvegardez avant et vérifiez les droits d écriture au déchiffrement.',
    'vault_help_notice': 'Remarques',
    'vault_help_n1': 'Le mot de passe et le sel déjà utilisés pour chiffrer ne sont pas modifiables ; créez un nouveau profil si besoin.',
    'vault_help_n2': 'Les fichiers chiffrés en bac à sable résident dans le répertoire privé de l application et sont supprimés à la désinstallation.',
    'vault_help_n3': 'En cas d oubli du mot de passe principal, aucun fichier chiffré n est récupérable : exportez toujours une sauvegarde.',
}

RU = {
    'vault_help': 'Справка',
    'vault_help_title': 'Справка по сейфу',
    'vault_help_intro': 'Сейф использует тот же формат crypt, что и rclone. Шифрование и расшифровка выполняются только на устройстве, ключ никогда его не покидает.',
    'vault_help_highlights': 'Основные возможности',
    'vault_help_hl1_title': 'Шифрование с нулевым разглашением',
    'vault_help_hl1_desc': 'Мастер-пароль и соль хранятся только на устройстве, поэтому ни облако, ни третьи лица не могут расшифровать файлы.',
    'vault_help_hl2_title': 'Совместимость с rclone и OpenList',
    'vault_help_hl2_desc': 'Используется тот же формат crypt, поэтому rclone на компьютере расшифрует те же файлы.',
    'vault_help_hl3_title': 'Несколько паролей и удалённое чтение',
    'vault_help_hl3_desc': 'Для каждой папки можно закрепить свой профиль пароля, а удалённые зашифрованные папки доступны для просмотра и воспроизведения без полной загрузки.',
    'vault_help_basics': 'Основные действия',
    'vault_help_b1_title': '1. Сначала задайте мастер-пароль',
    'vault_help_b1_desc': 'Задайте мастер-пароль и соль в разделе «Профили паролей» и запомните их; они не связаны с паролем разблокировки сейфа.',
    'vault_help_b2_title': '2. Зашифровать файлы',
    'vault_help_b2_desc': 'Выберите файлы в браузере, нажмите «Зашифровать» и выберите шифрование на месте или в песочнице.',
    'vault_help_b3_title': '3. Просмотр и открытие',
    'vault_help_b3_desc': 'Зашифрованные элементы перечислены в сейфе; нажатие временно расшифровывает их для предпросмотра.',
    'vault_help_b4_title': '4. Расшифровать',
    'vault_help_b4_desc': 'Выберите элемент и нажмите «Расшифровать», чтобы вернуть обычный файл на исходное место.',
    'vault_help_b5_title': '5. Резервная копия и восстановление',
    'vault_help_b5_desc': 'Экспортируйте резервную копию с профилями шифрования в разделе «Резервное копирование» перед удалением приложения.',
    'vault_help_compat': 'Совместимость',
    'vault_help_c1_title': 'Формат шифрования',
    'vault_help_c1_desc': 'Содержимое — XSalsa20-Poly1305; имена шифруются через EME и кодируются в base32/base64, при необходимости с суффиксом .bin.',
    'vault_help_c2_title': 'Облако и синхронизация',
    'vault_help_c2_desc': 'Шифротекст синхронизируется любым облаком или инструментом; сервер видит только шифротекст, но не реальные имена.',
    'vault_help_c3_title': 'Известные ограничения',
    'vault_help_c3_desc': 'Зашифрованные имена намного длиннее, слишком длинные могут не обработаться; переименовывайте только в приложении, правка шифрованного имени сделает файл нечитаемым.',
    'vault_help_inplace': 'Шифрование на месте',
    'vault_help_inplace_intro': 'Шифрование на месте шифрует файлы там, где они лежат: содержимое и имя заменяются шифротекстом, файл остаётся в исходной папке и не переносится в приватный каталог сейфа.',
    'vault_help_ip1_title': 'Связь с исходной папкой',
    'vault_help_ip1_desc': 'Расположение и структура папок не меняются; в браузере зашифрованные файлы помечаются значком замка.',
    'vault_help_ip2_title': 'Что видят другие приложения',
    'vault_help_ip2_desc': 'Другие менеджеры и плееры видят лишь бессмысленные шифрованные имена и не могут их открыть — в этом и состоит защита.',
    'vault_help_ip3_title': 'Когда применять',
    'vault_help_ip3_desc': 'Когда нужно сохранить структуру папок и чтобы сторонние облачные приложения продолжали синхронизировать эти файлы.',
    'vault_help_ip4_title': 'Риски и советы',
    'vault_help_ip4_desc': 'Шифрование напрямую заменяет исходный файл, и прерывание может оставить частичные файлы. Сделайте резервную копию и проверьте права на запись при расшифровке.',
    'vault_help_notice': 'Замечания',
    'vault_help_n1': 'Пароль и соль, уже использованные для шифрования, изменить нельзя; при необходимости создайте новый профиль.',
    'vault_help_n2': 'Файлы, зашифрованные в песочнице, хранятся в приватном каталоге приложения и удаляются вместе с ним.',
    'vault_help_n3': 'Если мастер-пароль утерян, восстановить зашифрованные файлы невозможно — всегда экспортируйте резервную копию.',
}

AR = {
    'vault_help': 'مساعدة',
    'vault_help_title': 'مساعدة الخزنة',
    'vault_help_intro': 'تستخدم الخزنة تنسيق crypt نفسه المستخدم في rclone. يتم التشفير وفك التشفير بالكامل على الجهاز، ولا يخرج المفتاح منه أبدًا.',
    'vault_help_highlights': 'أبرز المزايا',
    'vault_help_hl1_title': 'تشفير بدون معرفة مسبقة',
    'vault_help_hl1_desc': 'تبقى كلمة المرور الرئيسية والملح على هذا الجهاز فقط، فلا يمكن لأي خدمة سحابية أو طرف ثالث فك تشفير ملفاتك.',
    'vault_help_hl2_title': 'متوافق مع rclone و OpenList',
    'vault_help_hl2_desc': 'يستخدم نفس تنسيق crypt، لذلك يمكن لـ rclone على الكمبيوتر فك تشفير الملفات نفسها.',
    'vault_help_hl3_title': 'كلمات مرور متعددة وقراءة عن بُعد',
    'vault_help_hl3_desc': 'يمكن ربط ملف كلمة مرور مختلف بكل مجلد، ويمكن تصفح المجلدات المشفّرة عن بُعد وتشغيلها دون تنزيلها كاملة.',
    'vault_help_basics': 'العمليات الأساسية',
    'vault_help_b1_title': '١. اضبط كلمة المرور الرئيسية أولًا',
    'vault_help_b1_desc': 'اضبط كلمة المرور الرئيسية والملح في «ملفات كلمات المرور» واحفظهما جيدًا؛ فهما مستقلتان عن كلمة مرور فتح الخزنة.',
    'vault_help_b2_title': '٢. تشفير الملفات',
    'vault_help_b2_desc': 'حدد الملفات في المتصفح، ثم اضغط تشفير واختر التشفير في مكانه أو في وضع الحماية.',
    'vault_help_b3_title': '٣. العرض والفتح',
    'vault_help_b3_desc': 'تُدرج العناصر المشفّرة في الخزنة، وعند الضغط عليها تُفك تشفيرها مؤقتًا للمعاينة.',
    'vault_help_b4_title': '٤. فك التشفير',
    'vault_help_b4_desc': 'حدد عنصرًا واضغط فك التشفير لإعادته ملفًا عاديًا إلى مكانه الأصلي.',
    'vault_help_b5_title': '٥. النسخ الاحتياطي والاستعادة',
    'vault_help_b5_desc': 'صدّر من «النسخ الاحتياطي / الاستعادة» نسخة تتضمن ملفات التشفير قبل إزالة التطبيق.',
    'vault_help_compat': 'التوافق',
    'vault_help_c1_title': 'تنسيق التشفير',
    'vault_help_c1_desc': 'يستخدم المحتوى XSalsa20-Poly1305، وتُشفَّر الأسماء عبر EME ثم تُرمَّز بـ base32/base64، ويمكن إضافة اللاحقة .bin.',
    'vault_help_c2_title': 'السحابة والمزامنة',
    'vault_help_c2_desc': 'تتم مزامنة النص المشفّر مع أي سحابة أو أداة مزامنة؛ والخادم لا يرى سوى النص المشفّر ولا يعرف الأسماء الحقيقية.',
    'vault_help_c3_title': 'القيود المعروفة',
    'vault_help_c3_desc': 'الأسماء المشفّرة أطول بكثير، وقد تفشل الأسماء الطويلة جدًا؛ أعد التسمية داخل التطبيق فقط، فتعديل الاسم المشفّر يجعل الملف غير قابل لفك التشفير.',
    'vault_help_inplace': 'التشفير في مكانه',
    'vault_help_inplace_intro': 'يشفّر التشفير في مكانه الملفات حيث توجد: يستبدل المحتوى والاسم بنص مشفّر، ويبقى الملف في مجلده الأصلي دون الانتقال إلى مجلد الخزنة الخاص.',
    'vault_help_ip1_title': 'العلاقة بالمجلد الأصلي',
    'vault_help_ip1_desc': 'يبقى الموقع وهيكل المجلدات كما هو، وتظهر على الملفات المشفّرة شارة قفل في المتصفح.',
    'vault_help_ip2_title': 'ما تراه التطبيقات الأخرى',
    'vault_help_ip2_desc': 'ترى برامج إدارة الملفات والمشغلات الأخرى أسماءً مشفّرة بلا معنى ولا يمكنها فتحها، وهذا هو المقصود من الحماية.',
    'vault_help_ip3_title': 'متى تستخدمه',
    'vault_help_ip3_desc': 'عند الرغبة في الحفاظ على هيكل المجلدات مع استمرار تطبيقات السحابة الخارجية في مزامنة هذه الملفات.',
    'vault_help_ip4_title': 'المخاطر والنصائح',
    'vault_help_ip4_desc': 'يستبدل التشفير الملف الأصلي مباشرة، وقد يترك الانقطاع ملفات ناقصة. احتفظ بنسخة احتياطية أولًا وتحقق من صلاحية الكتابة عند فك التشفير.',
    'vault_help_notice': 'ملاحظات',
    'vault_help_n1': 'لا يمكن تغيير كلمة المرور والملح اللذين استُخدما بالفعل في التشفير؛ أنشئ ملفًا جديدًا عند الحاجة.',
    'vault_help_n2': 'تخزَّن الملفات المشفّرة في وضع الحماية داخل مجلد التطبيق الخاص وتُحذف عند إزالة التطبيق.',
    'vault_help_n3': 'في حال نسيان كلمة المرور الرئيسية لن يمكن استعادة أي ملف مشفّر، لذا صدّر نسخة احتياطية دائمًا.',
}

LANGS = {
    'en': EN, 'zh': ZH, 'zh_TW': ZH_TW, 'ja': JA, 'ko': KO,
    'de': DE, 'es': ES, 'fr': FR, 'ru': RU, 'ar': AR,
}

DART_LOCALES = ['en', 'zh', 'ar', 'de', 'es', 'fr', 'ja', 'ko', 'ru']


def read_bytes(path):
    with io.open(path, 'rb') as f:
        return f.read()


def write_bytes(path, data):
    with io.open(path, 'wb') as f:
        f.write(data)


def esc(s):
    return s.replace('\\', '\\\\').replace("'", "\\'")


def insert_arb(lang, table):
    path = os.path.join(ARB_DIR, 'app_%s.arb' % lang)
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = '"@crypt_settings_title"'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in %s' % path)
    end = text.find('\n  },', idx)
    if end < 0:
        end = text.find('\n  }', idx)
        if end < 0:
            raise SystemExit('meta end not found in %s' % path)
        end += len('\n  }')
    else:
        end += len('\n  },')

    lines = []
    for key in KEYS:
        lines.append('  "%s": "%s",' % (key, table[key].replace('"', '\\"')))
        lines.append('  "@%s": {' % key)
        lines.append('    "description": "vault help: %s"' % key)
        lines.append('  },')
    block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))

    text = text[:end] + nl.decode('utf-8') + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    with io.open(path, 'r', encoding='utf-8') as f:
        json.load(f)
    print('ARB  %-8s +%d keys' % (lang, len(KEYS)))


def insert_base():
    path = os.path.join(GEN_DIR, 'app_localizations.dart')
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = '  String get crypt_settings_title;'
    idx = text.find(anchor)
    if idx < 0:
        raise SystemExit('anchor not found in base')
    end = idx + len(anchor)

    lines = []
    for key in KEYS:
        lines.append('')
        lines.append('  /// No description provided for @%s.' % key)
        lines.append('  String get %s;' % key)
    block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))

    text = text[:end] + block + text[end:]
    write_bytes(path, text.encode('utf-8'))
    print('BASE app_localizations.dart +%d keys' % len(KEYS))


def insert_locale(lang):
    path = os.path.join(GEN_DIR, 'app_localizations_%s.dart' % lang)
    data = read_bytes(path)
    nl = b'\r\n' if b'\r\n' in data else b'\n'
    text = data.decode('utf-8')

    anchor = "  String get crypt_settings_title => '"
    occurrences = []
    pos = text.find(anchor)
    while pos >= 0:
        occurrences.append(pos)
        pos = text.find(anchor, pos + 1)
    if not occurrences:
        raise SystemExit('anchor not found in %s' % path)

    tables = [LANGS[lang]] if len(occurrences) == 1 else [ZH, ZH_TW]
    if len(occurrences) > 2:
        raise SystemExit('unexpected %d occurrences in %s' % (len(occurrences), path))

    for i in range(len(occurrences) - 1, -1, -1):
        start = occurrences[i]
        end = text.find("';", start)
        if end < 0:
            raise SystemExit('end not found in %s' % path)
        end += len("';")
        table = tables[i]
        lines = []
        for key in KEYS:
            lines.append('')
            lines.append('  @override')
            lines.append("  String get %s => '%s';" % (key, esc(table[key])))
        block = '\n'.join(lines).replace('\n', nl.decode('utf-8'))
        text = text[:end] + block + text[end:]

    write_bytes(path, text.encode('utf-8'))
    print('DART %-8s +%d keys (x%d)' % (lang, len(KEYS), len(occurrences)))


def main():
    for lang in sorted(LANGS.keys()):
        insert_arb(lang, LANGS[lang])
    insert_base()
    for lang in DART_LOCALES:
        insert_locale(lang)
    print('done')


if __name__ == '__main__':
    sys.exit(main())
