"""用 Gradle 缓存里的 kotlin-compiler-embeddable 真正编译指定 Kotlin 文件。

为什么需要它：本项目的铁律是「原生 Kotlin 改动只有真机构建才能验证」，因为
`flutter analyze` 完全不覆盖 Kotlin —— 已发生过 @hide API 一路通过到 release
构建才炸（用户手动构建一次成本极高）。有了这个脚本，改完原生侧可以**先本机
编译一次**，把「语法错误 / API 不存在 / 参数个数不符」在本地就打掉。

用法：
    python scripts/check_kotlin.py <file1.kt> [file2.kt ...]

退出码 0 = 编译通过。
"""
import glob
import os
import subprocess
import sys

CACHE = r"C:\Users\admin\.gradle\caches\modules-2\files-2.1"
# 项目 android/settings.gradle.kts 用的插件版本；优先用它，但缓存里未必四件套齐全。
KOTLIN_VERSION = "2.3.20"
# kotlin-compiler-embeddable 运行期缺一不可的依赖。
KOTLIN_MODULES = ("kotlin-compiler-embeddable", "kotlin-stdlib",
                  "kotlin-reflect", "kotlin-script-runtime")
ANDROID_JAR = r"D:\dev\android-sdk\platforms\android-37.0\android.jar"
OUT_DIR = r"C:\Users\admin\AppData\Local\Temp\zf_kotlin_check"


def _version_key(v: str):
    import re
    return tuple(int(x) if x.isdigit() else 0 for x in re.split(r"[.\-]", v))


def pick_kotlin_version() -> str:
    """挑一个「编译器运行期依赖四件套」齐全的版本。

    本机缓存里 kotlin-reflect 没有 2.3.20（项目声明的 2.3.20 版本），若硬用 2.3.20
    编译器会在启动时报 NoClassDefFoundError。编译器与 reflect 必须**同版本**，
    否则可能触发二进制不兼容 —— 故整体回退到都齐全的最高版本（本机为 2.2.21）。
    版本回退只影响「语法/API 校验」这一目的，被编译代码本身的能力不受影响。
    """
    def complete(v: str) -> bool:
        return all(
            os.path.isdir(os.path.join(CACHE, "org.jetbrains.kotlin", m, v))
            for m in KOTLIN_MODULES
        )

    if complete(KOTLIN_VERSION):
        return KOTLIN_VERSION
    versions = set()
    for m in KOTLIN_MODULES:
        d = os.path.join(CACHE, "org.jetbrains.kotlin", m)
        if os.path.isdir(d):
            versions |= set(os.listdir(d))
    cands = [v for v in versions if complete(v)]
    if not cands:
        raise SystemExit("!! 缓存里找不到 Kotlin 四件套齐全的版本，无法本机编译验证")
    return sorted(cands, key=_version_key)[-1]


def find_jar(group: str, module: str, version: str, name_part: str) -> str:
    """缓存层级是 <group>/<module>/<version>/[<sha1>/]<file>.jar —— sha1 层可有可无
    （Kotlin 系只有一层，io.flutter 系有两层），故用递归 glob 一网打尽。"""
    pat = os.path.join(CACHE, group, module, version, "**", "*.jar")
    hits = [p for p in glob.glob(pat, recursive=True)
            if "sources" not in p and name_part in os.path.basename(p)]
    if not hits:
        raise SystemExit(f"!! 找不到 jar: {group}/{module}/{version}/{name_part}")
    return hits[0]


def main() -> int:
    # --syntax-only：给「依赖太多、无法凑齐 classpath」的大文件（MainActivity.kt
    #   引用了 R 类、各家 AAR、插件类……）用的降级模式：忽略「找不到符号」这类
    #   由 classpath 缺失导致的错误，只报**真正的语法/结构错误**。
    argv = sys.argv[1:]
    syntax_only = "--syntax-only" in argv
    emit_path = None
    srcs = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--emit":
            i += 1
            emit_path = argv[i] if i < len(argv) else None
        elif not a.startswith("--"):
            srcs.append(a)
        i += 1
    if not srcs:
        raise SystemExit("用法: python scripts/check_kotlin.py [--syntax-only] "
                         "[--emit out.txt] <file.kt> [...]")
    for s in srcs:
        if not os.path.isfile(s):
            raise SystemExit(f"!! 源文件不存在: {s}")

    kv = pick_kotlin_version()
    compiler = find_jar("org.jetbrains.kotlin", "kotlin-compiler-embeddable",
                        kv, "kotlin-compiler-embeddable")
    stdlib = find_jar("org.jetbrains.kotlin", "kotlin-stdlib",
                      kv, "kotlin-stdlib")
    embedding = find_jar("io.flutter", "flutter_embedding_release", "*",
                         "flutter_embedding_release")
    if not os.path.isfile(ANDROID_JAR):
        raise SystemExit(f"!! android.jar 不存在: {ANDROID_JAR}")

    os.makedirs(OUT_DIR, exist_ok=True)
    classpath = ";".join([stdlib, ANDROID_JAR, embedding])

    # 编译器进程自身还需要一串运行时依赖（stdlib / reflect / script-runtime …），
    # 缺一个就 NoClassDefFoundError。直接从缓存里把 org.jetbrains.kotlin 同版本的
    # jar 全捞上 —— 这与 -classpath（**被编译代码**的依赖）是两回事。
    runtime_cp = [compiler]
    kotlin_root = os.path.join(CACHE, "org.jetbrains.kotlin")
    for mod in sorted(os.listdir(kotlin_root)) if os.path.isdir(kotlin_root) else []:
        vdir = os.path.join(kotlin_root, mod, kv)
        if not os.path.isdir(vdir):
            continue
        for jar in glob.glob(os.path.join(vdir, "**", "*.jar"), recursive=True):
            base = os.path.basename(jar)
            if "sources" in base or "javadoc" in base:
                continue
            if jar not in runtime_cp:
                runtime_cp.append(jar)
    # 其余编译器运行期依赖（annotations / coroutines / trove4j …），按模块名从
    # 缓存里各捞一个最新版本的 jar。
    extra_modules = [
        ("org.jetbrains", "annotations"),
        # 注意模块名带 -jvm 后缀（Kotlin 多平台构件只在这里出 jar）
        ("org.jetbrains.kotlinx", "kotlinx-coroutines-core-jvm"),
        ("org.jetbrains.intellij.deps", "trove4j"),
    ]
    for group, module in extra_modules:
        root = os.path.join(CACHE, group, module)
        if not os.path.isdir(root):
            continue
        versions = sorted(os.listdir(root), key=_version_key)
        for v in reversed(versions):  # 从最新往下，取第一个能捞到 jar 的
            jars = [j for j in glob.glob(os.path.join(root, v, "**", "*.jar"),
                                         recursive=True)
                    if "sources" not in j and "javadoc" not in j]
            if jars:
                runtime_cp.extend(j for j in jars if j not in runtime_cp)
                break

    cmd = [
        "java", "-cp", ";".join(runtime_cp),
        "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
        *srcs,
        "-classpath", classpath,
        "-d", OUT_DIR,
        "-jvm-target", "17",
        # 依赖已由 -classpath 显式给出，禁掉「去 Kotlin home 找 stdlib/reflect」的
        # 那三条无意义警告。
        "-no-stdlib", "-no-reflect",
        "-nowarn",
    ]
    if kv != KOTLIN_VERSION:
        print("== 注意：项目声明 %s，但缓存里 kotlin-reflect 缺失，回退用 %s 校验"
              % (KOTLIN_VERSION, kv))
    print("== kotlinc(embeddable) %s" % kv)
    for s in srcs:
        print("   src:", os.path.basename(s))
    print("   android.jar:", ANDROID_JAR)
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    out = (proc.stdout or "") + (proc.stderr or "")
    lines = [ln.rstrip() for ln in out.splitlines() if ln.strip()]
    errors = [ln for ln in lines if ": error:" in ln]
    exceptions = [ln for ln in lines if "exception:" in ln.lower()]

    # 「符号找不到」是 classpath 缺失的表现，不是代码写错。
    MISSING_SYMBOL = ("unresolved reference", "cannot access", "cannot infer",
                      "not enough information to infer", "cannot find a parameter",
                      "cannot find symbol")
    real_errors = [ln for ln in errors
                   if not any(m in ln.lower() for m in MISSING_SYMBOL)]

    # --emit <文件>：把错误「指纹」（剥掉路径与行列号）落盘，便于与基线版本 diff。
    # 这是验证「改动是否引入新错误」最可靠的手段：本机编译不了的大文件（缺依赖
    # 导致一堆连带错误）也能用「改前/改后错误集合是否一致」来证明改动无害。
    if emit_path:
        import re
        fingerprints = sorted(set(re.sub(r"^.*?:\d+:\d+: ", "", e) for e in errors))
        with open(emit_path, "w", encoding="utf-8") as f:
            for fp in fingerprints:
                f.write(fp + "\n")
        print("== 错误指纹已写入 %s（%d 条去重）" % (emit_path, len(fingerprints)))

    print("== 错误 %d 条（其中「符号缺失」%d 条，真实错误 %d 条）"
          % (len(errors), len(errors) - len(real_errors), len(real_errors)))
    if syntax_only:
        print("== --syntax-only：只判真实错误（忽略符号缺失）")
        show = real_errors
        code = 1 if (real_errors or exceptions) else 0
    else:
        show = errors
        code = proc.returncode
    for ln in (exceptions + show)[:60]:
        print("  " + ln)
    print("EXIT", code)
    return code


if __name__ == "__main__":
    sys.exit(main())
