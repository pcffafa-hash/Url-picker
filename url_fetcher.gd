extends Control
# URL Fetcher für Godot 4.x
# Setup: Neue Szene -> Root "Control" -> dieses Script dranhängen -> F5.
# Die komplette UI wird im Code gebaut.

const HEADERS := [
	"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0 Safari/537.36",
	"Accept: */*",
]

# Alle gefundenen Links liegen nur im RAM: {url, type}
var found: Array[Dictionary] = []
var seen := {}
var visited := {}
var last_html := ""
var api_count := 0
var dbg_btn: Button
var busy := false
var out_dir := ""
var deob_cache := {}

var url_edit: LineEdit
var mode_opt: OptionButton
var scan_btn: Button
var dl_btn: Button
var list: ItemList
var log_label: RichTextLabel
var progress: ProgressBar
var js_chk: CheckBox


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var th := Theme.new()
	th.default_font_size = 24
	theme = th
	out_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS).path_join("UrlFetcher")
	_build_ui()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 12)
	add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	url_edit = LineEdit.new()
	url_edit.placeholder_text = "https://webseite.de/seite"
	vb.add_child(url_edit)

	url_edit.custom_minimum_size.y = 64

	mode_opt = OptionButton.new()
	mode_opt.add_item("Modus 1: M3U8 + VOE", 0)
	mode_opt.add_item("Modus 2: Normal (mp4, webm ...)", 1)
	mode_opt.custom_minimum_size.y = 64
	vb.add_child(mode_opt)

	js_chk = CheckBox.new()
	js_chk.text = "JavaScript ausführen (Termux-Server)"
	js_chk.custom_minimum_size.y = 56
	vb.add_child(js_chk)

	scan_btn = Button.new()
	scan_btn.text = "Suchen"
	scan_btn.custom_minimum_size.y = 64
	scan_btn.pressed.connect(_on_scan)
	vb.add_child(scan_btn)

	list = ItemList.new()
	list.max_text_lines = 3
	list.auto_height = false
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(list)

	dl_btn = Button.new()
	dl_btn.text = "Alles downloaden"
	dl_btn.custom_minimum_size.y = 64
	dl_btn.pressed.connect(_on_download_all)
	vb.add_child(dl_btn)

	dbg_btn = Button.new()
	dbg_btn.text = "Debug: Quelltext kopieren"
	dbg_btn.custom_minimum_size.y = 56
	dbg_btn.pressed.connect(_on_debug_copy)
	vb.add_child(dbg_btn)

	progress = ProgressBar.new()
	progress.step = 1
	vb.add_child(progress)

	log_label = RichTextLabel.new()
	log_label.custom_minimum_size.y = 180
	log_label.scroll_following = true
	vb.add_child(log_label)


func log_msg(t: String) -> void:
	log_label.append_text(t + "\n")


# ---------------------------------------------------------------- Suchen

func _on_scan() -> void:
	if busy:
		return
	var url := url_edit.text.strip_edges()
	if url == "":
		return
	if not url.begins_with("http"):
		url = "https://" + url

	busy = true
	found.clear()
	seen.clear()
	visited.clear()
	api_count = 0
	deob_cache.clear()
	list.clear()
	log_msg("Lade Seite: " + url)

	var html := await fetch_page(url, "")
	if html == "":
		log_msg("[color=red]Seite konnte nicht geladen werden.[/color]")
		busy = false
		return
	log_msg("Seite geladen: %d Zeichen" % html.length())
	last_html = html
	log_msg("Scripts: %d | Iframes: %d | m3u8: %d | voe: %d | mp4: %d | atob: %d" % [
		html.count("<script"), html.count("<iframe"), html.count("m3u8"),
		html.to_lower().count("voe"), html.count(".mp4"), html.count("atob(")])

	extract(html, url)
	await scan_scripts(html, url)
	await probe_apis(html, url)

	var cands := find_candidates(html, url)
	log_msg("%d Kandidaten (Iframes / Player-Links)" % cands.size())
	for c in cands:
		await scan_candidate(c, url, 0)

	log_msg("Fertig: %d Links im RAM." % found.size())
	if found.is_empty():
		log_msg("[color=orange]Nichts gefunden. Die Seite lädt die Links evtl. erst per JavaScript nach.[/color]")
	busy = false


func scan_candidate(c: String, referer: String, depth: int) -> void:
	if depth > 2 or visited.has(c) or visited.size() > 40:
		return
	visited[c] = true

	if mode_opt.selected == 0 and is_voe(c):
		add_link(c, "voe")
		return

	var final := await follow_redirects(c, referer)
	if final != c:
		log_msg("Redirect -> " + final)
		if mode_opt.selected == 0 and is_voe(final):
			add_link(final, "voe")
			return

	var sub := await fetch_page(final, referer)
	if sub == "":
		return
	extract(sub, final)
	await scan_scripts(sub, final)
	await probe_apis(sub, final)

	for nxt in find_js_redirects(sub, final):
		await scan_candidate(nxt, final, depth + 1)
	for nxt in find_candidates(sub, final):
		await scan_candidate(nxt, final, depth + 1)


# Externe JavaScript-Dateien laden und ebenfalls nach Links durchsuchen
func scan_scripts(html: String, base: String) -> void:
	var skip := ["jquery", "google", "gstatic", "analytics", "bootstrap", "fontawesome",
		"facebook", "doubleclick", "gtag", "adsbygoogle", "cloudflare", "cdnjs",
		"jsdelivr", "unpkg", "recaptcha"]
	var re := RegEx.new()
	re.compile("<script[^>]+src=[\"']([^\"']+)[\"']")
	var n := 0
	for m in re.search_all(normalize(deobfuscate(html))):
		var js := resolve(base, m.get_string(1))
		if js == "" or visited.has("js:" + js):
			continue
		var low := js.to_lower()
		var bad := false
		for k in skip:
			if low.contains(k):
				bad = true
		if bad:
			continue
		visited["js:" + js] = true
		n += 1
		if n > 15:
			break
		var code := await fetch_text(js, base)
		if code != "":
			log_msg("JS geladen: " + js.get_file().get_slice("?", 0))
			extract(code, js)
			await probe_apis(code, js)


# ---------------------------------------------------------------- Entpacker
# Ersatz fuer "JavaScript ausfuehren": bekannte Verschleierungen werden aufgeloest,
# das Ergebnis wird an den Originaltext angehaengt und dann normal durchsucht.
# Unterstuetzt: eval(function(p,a,c,k,e,d)...) Packer, \xNN / \uNNNN, atob("..."),
# lange Base64-Strings, "...".split("").reverse().join("")

func deobfuscate(text: String) -> String:
	if text == "":
		return ""
	var key := text.hash()
	if deob_cache.has(key):
		return deob_cache[key]
	var t := decode_escapes(text)
	var res := t + "\n" + _deob_extra(t, 0)
	deob_cache[key] = res
	return res


func _deob_extra(t: String, depth: int) -> String:
	var extra := unpack_packer(t) + decode_atob(t) + decode_reversed(t) + decode_b64(t)
	if extra != "" and depth < 3:
		var e2 := decode_escapes(extra)
		extra = e2 + "\n" + _deob_extra(e2, depth + 1)
	return extra


# \xNN und \uNNNN in echte Zeichen umwandeln
func decode_escapes(text: String) -> String:
	if not (text.contains("\\x") or text.contains("\\u")):
		return text
	var re := RegEx.new()
	re.compile("\\\\(?:x([0-9a-fA-F]{2})|u([0-9a-fA-F]{4}))")
	var out := ""
	var pos := 0
	for m in re.search_all(text):
		out += text.substr(pos, m.get_start() - pos)
		var hex := m.get_string(1) if m.get_string(1) != "" else m.get_string(2)
		var code := hex.hex_to_int()
		if code < 32 or (code >= 0xD800 and code <= 0xDFFF):
			out += m.get_string()
		else:
			out += char(code)
		pos = m.get_end()
	return out + text.substr(pos)


# Dean-Edwards-Packer: eval(function(p,a,c,k,e,d){...}('payload',base,count,'a|b|c'.split('|'),0,{}))
func unpack_packer(text: String) -> String:
	if not (text.contains("function(p,a,c,k") or text.contains("function(p, a, c, k")):
		return ""
	var re := RegEx.new()
	re.compile("\\}\\((['\"])((?:(?!\\1)[^\\\\]|\\\\.)*)\\1,\\s*(\\d+),\\s*(\\d+),\\s*(['\"])((?:(?!\\5)[^\\\\]|\\\\.)*)\\5\\.split\\((['\"])\\|\\7\\)")
	var wre := RegEx.new()
	wre.compile("\\b\\w+\\b")
	var out := ""
	for m in re.search_all(text):
		var base := int(m.get_string(3))
		if base < 2:
			continue
		var payload := js_unquote(m.get_string(2))
		var keys := js_unquote(m.get_string(6)).split("|")
		var res := ""
		var pos := 0
		for w in wre.search_all(payload):
			res += payload.substr(pos, w.get_start() - pos)
			var word := w.get_string()
			var idx := _unbase(word, base)
			if idx >= 0 and idx < keys.size() and keys[idx] != "" and _tobase(idx, base) == word:
				res += keys[idx]
			else:
				res += word
			pos = w.get_end()
		res += payload.substr(pos)
		out += res + "\n"
	if out != "":
		log_msg("Packer entpackt: %d Zeichen" % out.length())
	return out


func js_unquote(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if c == "\\" and i + 1 < s.length():
			var n := s[i + 1]
			if n == "n" or n == "r" or n == "t":
				out += " "
			elif n == "x" or n == "u":
				out += "\\" + n
			else:
				out += n
			i += 2
		else:
			out += c
			i += 1
	return out


func _unbase(w: String, base: int) -> int:
	var v := 0
	for ch in w:
		var c := ch.unicode_at(0)
		var d := -1
		if c >= 48 and c <= 57:
			d = c - 48
		elif c >= 97 and c <= 122:
			d = c - 87
		elif c >= 65 and c <= 90:
			d = c - 29
		if d < 0 or d >= base:
			return -1
		v = v * base + d
	return v


@warning_ignore("integer_division")
func _tobase(v: int, base: int) -> String:
	var d := v % base
	var ch := ""
	if d < 10:
		ch = char(48 + d)
	elif d < 36:
		ch = char(87 + d)
	else:
		ch = char(29 + d)
	if v < base:
		return ch
	return _tobase(v / base, base) + ch


# atob("...") mit kurzen Strings
func decode_atob(text: String) -> String:
	if not text.contains("atob("):
		return ""
	var out := ""
	var re := RegEx.new()
	re.compile("atob\\(\\s*[\"']([A-Za-z0-9+/=]{8,})[\"']\\s*\\)")
	for m in re.search_all(text):
		var dec := _b64_text(m.get_string(1))
		if dec != "":
			out += dec + "\n"
	return out


# "...".split("").reverse().join("")
func decode_reversed(text: String) -> String:
	if not text.contains(".reverse()"):
		return ""
	var out := ""
	var re := RegEx.new()
	re.compile("[\"']([^\"'\\n]{10,})[\"']\\s*\\.split\\(\\s*[\"']{2}\\s*\\)\\s*\\.reverse\\(\\)\\s*\\.join\\(\\s*[\"']{2}\\s*\\)")
	for m in re.search_all(text):
		var parts := m.get_string(1).split("")
		parts.reverse()
		out += "".join(parts) + "\n"
	return out


# Base64 -> Text. Binaerdaten werden verworfen (keine UTF-8-Fehler)
func _b64_text(s: String) -> String:
	var b64 := s.rstrip("=")
	match b64.length() % 4:
		1:
			b64 = b64.left(-1)
		2:
			b64 += "=="
		3:
			b64 += "="
	var raw := Marshalls.base64_to_raw(b64)
	if raw.is_empty() or not looks_like_text(raw, true, 100000):
		return ""
	return raw.get_string_from_utf8()


# Base64-Strings im Text dekodieren, damit versteckte Links sichtbar werden
func decode_b64(text: String) -> String:
	var out := ""
	var re := RegEx.new()
	re.compile("[A-Za-z0-9+/]{40,}={0,2}")
	var n := 0
	for m in re.search_all(text):
		n += 1
		if n > 300:
			break
		var dec := _b64_text(m.get_string())
		if dec.contains("http") or dec.contains("m3u8") or dec.contains(".mp4") or dec.contains("eval("):
			out += dec + "\n"
	return out


# Prueft die Bytes: nur druckbares ASCII / Whitespace -> Text, sonst Binaerdaten
func looks_like_text(b: PackedByteArray, strict := true, limit := 2000) -> bool:
	var n := mini(b.size(), limit)
	for i in n:
		var c := b[i]
		if c == 0:
			return false
		if strict and c > 126:
			return false
		if c < 32 and c != 9 and c != 10 and c != 13:
			return false
	return true


# Browser-Ersatz: API-/Ajax-URLs aus HTML und JS suchen, abrufen und die Antworten durchsuchen
func probe_apis(text: String, base: String) -> void:
	var keys := ["api", "ajax", "embed", "source", "player", "stream", "video",
		"hoster", "episode", "getlink", "get_link", "link", "movie", "watch", "play", "json"]
	var bad_words := ["logout", "login", "register", "delete", "signup", "password"]
	var bad_ext := [".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico",
		".webp", ".woff", ".woff2", ".ttf", ".map"]
	var re := RegEx.new()
	re.compile("[\"'`]((?:https?:)?/[^\"'`\\s]{3,200})[\"'`]")
	for m in re.search_all(normalize(text + "\n" + unpack_packer(text))):
		if api_count >= 20:
			return
		var raw := m.get_string(1)
		var low := raw.to_lower()
		if raw.begins_with("//") and not raw.begins_with("//" + base.get_slice("/", 2)):
			pass
		if low.contains("{") or low.contains("$") or low.contains("<") or low.contains("(") or low.contains("*"):
			continue
		var skip := false
		for b in bad_words:
			if low.contains(b):
				skip = true
		for e in bad_ext:
			if low.get_slice("?", 0).ends_with(e):
				skip = true
		if skip:
			continue
		var ok := false
		for k in keys:
			if low.contains(k):
				ok = true
		if not ok:
			continue
		var api := resolve(base, raw)
		if api == "" or visited.has("api:" + api):
			continue
		visited["api:" + api] = true
		api_count += 1
		var body := await fetch_text(api, base)
		if body == "":
			continue
		log_msg("API: " + api.get_slice("?", 0).right(60))
		extract(body, api)


func _on_debug_copy() -> void:
	var info := "Quelltext (%d Zeichen), gefunden: %d\n\n" % [last_html.length(), found.size()]
	DisplayServer.clipboard_set(info + last_html.substr(0, 15000))
	log_msg("Quelltext (max. 15000 Zeichen) in die Zwischenablage kopiert.")


func is_voe(u: String) -> bool:
	var re := RegEx.new()
	re.compile("^https?://[^/]*voe[^/]*/")
	return re.search(u) != null


func follow_redirects(url: String, referer: String) -> String:
	var cur := url
	for i in 5:
		var req := HTTPRequest.new()
		req.max_redirects = 0
		add_child(req)
		var h := PackedStringArray(HEADERS)
		if referer != "":
			h.append("Referer: " + referer)
		if req.request(cur, h) != OK:
			req.queue_free()
			break
		var res = await req.request_completed
		req.queue_free()
		if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 300 or res[1] >= 400:
			break
		var loc := ""
		for hd in res[2]:
			if str(hd).to_lower().begins_with("location:"):
				loc = str(hd).substr(9).strip_edges()
		if loc == "":
			break
		cur = resolve(cur, loc)
	return cur


func find_js_redirects(html: String, base: String) -> Array[String]:
	var res: Array[String] = []
	var re := RegEx.new()
	re.compile("(?:location\\.href|window\\.location|location\\.replace\\()\\s*=?\\s*\\(?\\s*[\"'](https?://[^\"']+)[\"']")
	for m in re.search_all(normalize(deobfuscate(html))):
		var l := m.get_string(1)
		if not res.has(l):
			res.append(l)
	return res


func normalize(html: String) -> String:
	return html.replace("\\/", "/").replace("\\u0026", "&").replace("\\u002F", "/").replace("\\u002f", "/").replace("\\x2F", "/").replace("\\x2f", "/").replace("&amp;", "&")


func extract(html_raw: String, base: String) -> void:
	var html := normalize(deobfuscate(html_raw))

	if mode_opt.selected == 0:
		# M3U8
		_collect(html, "[\"'(]([^\"'\\s()<>]+\\.m3u8[^\"'\\s()<>]*)", base, "m3u8")
		# VOE
		_collect(html, "(https?://[a-zA-Z0-9.-]*voe[a-zA-Z0-9.-]*/[^\\s\"'<>\\\\]+)", base, "voe")
	else:
		_collect(html, "[\"'(]([^\"'\\s()<>]+\\.(?:mp4|webm|mkv|mov|avi|m4v|flv)(?:\\?[^\"'\\s()<>]*)?)", base, "video")


func _collect(html: String, pattern: String, base: String, type: String) -> void:
	var re := RegEx.new()
	re.compile(pattern)
	for m in re.search_all(html):
		var link := resolve(base, m.get_string(1))
		if link != "":
			add_link(link, type)


func add_link(link: String, type: String) -> void:
	if seen.has(link):
		return
	seen[link] = true
	found.append({"url": link, "type": type})
	list.add_item("[%s] %s" % [type.to_upper(), link])


func find_candidates(html: String, base: String) -> Array[String]:
	var res: Array[String] = []
	var h := normalize(deobfuscate(html))

	var re_if := RegEx.new()
	re_if.compile("<iframe[^>]+(?:src|data-src)=[\"']([^\"']+)[\"']")
	for m in re_if.search_all(h):
		var l := resolve(base, m.get_string(1))
		if l != "" and not res.has(l):
			res.append(l)

	var keys := ["redirect", "embed", "player", "hoster", "stream", "voe", "/e/", "/r/"]
	var skip := [".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico", ".webp"]
	var re_at := RegEx.new()
	re_at.compile("(?:href|data-[a-z-]+)=[\"']([^\"']+)[\"']")
	for m in re_at.search_all(h):
		var raw := m.get_string(1)
		var low := raw.to_lower()
		if raw.begins_with("#") or low.begins_with("javascript") or low.begins_with("mailto"):
			continue
		var bad := false
		for sk in skip:
			if low.get_slice("?", 0).ends_with(sk):
				bad = true
		if bad:
			continue
		var ok := false
		for k in keys:
			if low.contains(k):
				ok = true
		if not ok:
			continue
		var l := resolve(base, raw)
		if l != "" and not res.has(l):
			res.append(l)
		if res.size() >= 25:
			break
	return res


func resolve(base: String, link: String) -> String:
	link = link.strip_edges()
	if link.begins_with("http"):
		return link
	if link.begins_with("//"):
		return base.get_slice(":", 0) + ":" + link
	var re := RegEx.new()
	re.compile("^(https?://[^/]+)")
	var m := re.search(base)
	if m == null:
		return ""
	var origin := m.get_string(1)
	if link.begins_with("/"):
		return origin + link
	var dir := base.get_slice("?", 0)
	dir = dir.substr(0, dir.rfind("/") + 1)
	if dir.length() <= origin.length() + 1:
		dir = origin + "/"
	return dir + link


# ---------------------------------------------------------------- HTTP

const JS_SERVER := "http://127.0.0.1:8787/render?url="


# Seite laden; mit Haken laeuft das JavaScript vorher im Termux-Server (jsdom)
func fetch_page(url: String, referer: String) -> String:
	if js_chk.button_pressed:
		var r := await fetch_rendered(url, referer)
		if r != "":
			log_msg("JS-Server: Seite gerendert (%d Zeichen)" % r.length())
			return r
		log_msg("[color=orange]JS-Server nicht erreichbar oder Fehler -> normaler Abruf[/color]")
	return await fetch_text(url, referer)


# Liefert das gerenderte HTML plus alle vom JS angefragten URLs (in Anfuehrungszeichen,
# damit die normalen Regex in extract() sie finden)
func fetch_rendered(url: String, referer: String) -> String:
	var req := HTTPRequest.new()
	req.timeout = 40
	add_child(req)
	if req.request(JS_SERVER + url.uri_encode() + "&ref=" + referer.uri_encode()) != OK:
		req.queue_free()
		return ""
	var res = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		return ""
	var data = JSON.parse_string(res[3].get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	var lines := PackedStringArray()
	for u in data.get("requests", []):
		lines.append('"' + str(u) + '"')
	return str(data.get("html", "")) + "\n" + "\n".join(lines)


func _request(url: String, referer: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.max_redirects = 8
	add_child(req)
	var h := PackedStringArray(HEADERS)
	if referer != "":
		h.append("Referer: " + referer)
	if req.request(url, h) != OK:
		req.queue_free()
		return {}
	var res = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] >= 400:
		return {}
	var ct := ""
	for hd in res[2]:
		var hs := str(hd)
		if hs.to_lower().begins_with("content-type:"):
			ct = hs.substr(13).strip_edges().to_lower()
	return {"ctype": ct, "body": res[3]}


func fetch_bytes(url: String, referer: String) -> PackedByteArray:
	var r := await _request(url, referer)
	if r.is_empty():
		return PackedByteArray()
	return r.body


func fetch_text(url: String, referer: String) -> String:
	var r := await _request(url, referer)
	if r.is_empty():
		return ""
	var ct: String = r.ctype
	for pre in ["image/", "video/", "audio/", "font/", "application/pdf", "application/zip", "application/font"]:
		if ct.begins_with(pre):
			return ""
	var body: PackedByteArray = r.body
	if body.size() > 4000000 or not looks_like_text(body, false):
		return ""
	return body.get_string_from_utf8()


func download_file(url: String, path: String, referer: String) -> bool:
	var req := HTTPRequest.new()
	req.max_redirects = 8
	req.download_file = path
	add_child(req)
	var h := PackedStringArray(HEADERS)
	if referer != "":
		h.append("Referer: " + referer)
	if req.request(url, h) != OK:
		req.queue_free()
		return false
	var res = await req.request_completed
	req.queue_free()
	return res[0] == HTTPRequest.RESULT_SUCCESS and res[1] < 400


# ---------------------------------------------------------------- Download

func _on_download_all() -> void:
	if busy or found.is_empty():
		return
	busy = true
	DirAccess.make_dir_recursive_absolute(out_dir)
	if not DirAccess.dir_exists_absolute(out_dir):
		out_dir = ProjectSettings.globalize_path("user://downloads")
		DirAccess.make_dir_recursive_absolute(out_dir)
	progress.max_value = found.size()
	progress.value = 0
	log_msg("Speichere nach: " + out_dir)

	var i := 0
	for item in found:
		i += 1
		var ok := await download_item(item, i)
		log_msg(("[color=green]OK[/color] " if ok else "[color=red]Fehler[/color] ") + item.url)
		progress.value = i

	log_msg("Alle Downloads durch.")
	busy = false


func download_item(item: Dictionary, idx: int) -> bool:
	var url: String = item.url
	var name := "video_%03d" % idx
	match item.type:
		"m3u8":
			return await download_hls(url, out_dir.path_join(name + ".ts"), url_edit.text)
		"video":
			var ext := url.get_slice("?", 0).get_extension()
			if ext == "":
				ext = "mp4"
			return await download_file(url, out_dir.path_join(name + "." + ext), url_edit.text)
		"voe":
			return await download_voe(url, name)
	return false


# VOE-Embedseite laden, Weiterleitungen folgen, echte Quelle suchen
func download_voe(url: String, name: String) -> bool:
	var cur := url
	for i in 4:
		var html := normalize(deobfuscate(await fetch_text(cur, url_edit.text)))
		if html == "":
			return false
		var re_m3u8 := RegEx.new()
		re_m3u8.compile("[\"'(]([^\"'\\s()<>]+\\.m3u8[^\"'\\s()<>]*)")
		var m := re_m3u8.search(html)
		if m:
			return await download_hls(resolve(cur, m.get_string(1)), out_dir.path_join(name + ".ts"), cur)
		var re_mp4 := RegEx.new()
		re_mp4.compile("[\"'(]([^\"'\\s()<>]+\\.mp4[^\"'\\s()<>]*)")
		m = re_mp4.search(html)
		if m:
			return await download_file(resolve(cur, m.get_string(1)), out_dir.path_join(name + ".mp4"), cur)
		var nxt := find_js_redirects(html, cur)
		if nxt.is_empty():
			break
		log_msg("VOE Weiterleitung -> " + nxt[0])
		cur = nxt[0]
	log_msg("VOE: keine Quelle auf der Seite gefunden (evtl. verschleiert).")
	return false


# HLS: Master-Playlist -> beste Qualität -> alle Segmente in eine .ts schreiben
func download_hls(url: String, path: String, referer: String) -> bool:
	var text := await fetch_text(url, referer)
	if text == "":
		return false
	var lines := text.split("\n", false)

	# Master-Playlist?
	if text.contains("#EXT-X-STREAM-INF"):
		var best_bw := -1
		var best_uri := ""
		var bw_re := RegEx.new()
		bw_re.compile("BANDWIDTH=(\\d+)")
		for i in lines.size():
			var l := lines[i].strip_edges()
			if l.begins_with("#EXT-X-STREAM-INF"):
				var bm := bw_re.search(l)
				var bw := int(bm.get_string(1)) if bm else 0
				for j in range(i + 1, lines.size()):
					var u := lines[j].strip_edges()
					if u != "" and not u.begins_with("#"):
						if bw > best_bw:
							best_bw = bw
							best_uri = u
						break
		if best_uri == "":
			return false
		return await download_hls(resolve(url, best_uri), path, referer)

	if text.contains("METHOD=AES-128"):
		log_msg("[color=orange]Verschlüsselte Segmente (AES-128) werden nicht unterstützt.[/color]")
		return false

	var segs: Array[String] = []
	for l in lines:
		var s := l.strip_edges()
		if s != "" and not s.begins_with("#"):
			segs.append(resolve(url, s))
	if segs.is_empty():
		return false

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	var n := 0
	for seg in segs:
		var data := await fetch_bytes(seg, referer)
		if data.is_empty():
			f.close()
			return false
		f.store_buffer(data)
		n += 1
		if n % 20 == 0:
			log_msg("  Segment %d / %d" % [n, segs.size()])
	f.close()
	return true
