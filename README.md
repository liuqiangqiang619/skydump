# SkyDump —— SkyCam 面板结构导出（只读诊断）

## 它做什么
把注入 App 里所有 WKWebView 的页面导出来：href / title / outerHTML / 全部 CSS 规则，
以及 App 自己注入的 WKUserScript 源码。不改任何页面、不改业务逻辑。

## 步骤
1. 把 uild\SkyDump.dylib（71,592 字节）用全能签注入到目标 App（和 IMUOnly 一起注入即可，两者不冲突）
2. PC 上以管理员执行一次开放端口：
   
etsh advfirewall firewall add rule name="SkyDump-9805" dir=in action=allow protocol=TCP localport=9805
3. PC 双击 ecv.bat（监听 9805，落盘到本目录）
4. 手机上打开 SkyCam 面板，停留 3–5 秒
5. PC 目录里会出现 skydump.json（以及 html_*.html / userscript_*.css）

## 输出
- skydump.json —— {href,title,html,styles}
- html_*.html —— 若面板是用 loadHTMLString 塞进去的，原样保存
- userscript_*.css —— App 注入的脚本（它自己的主题 CSS 就在里面）

## 默认通道
dylib 默认连 192.168.10.2:9805；要改的话在 App 的 UserDefaults 里写 SKYDumpHost。