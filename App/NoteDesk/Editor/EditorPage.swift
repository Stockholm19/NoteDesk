import Foundation

/// HTML-страница редактора: contenteditable поверх родного HTML Note Station.
/// Форматирование не конвертируется — что пришло с сервера, то и уходит обратно.
/// Всё, что редактор подменяет для показа (src картинок и чекбоксов), хранится
/// в data-nd-src и возвращается на место в serialize().
enum EditorPage {
    static let html = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<style>
  :root { color-scheme: light dark; }
  html, body { margin: 0; padding: 0; }
  body {
    font-family: -apple-system, system-ui, sans-serif;
    font-size: 16px; line-height: 1.4;
    padding: 12px 20px 80px;
    word-wrap: break-word;
    -webkit-user-select: text;
  }
  #ed { outline: none; min-height: 60vh; }
  #ed:empty::before { content: attr(data-placeholder); color: #999; }
  /* Строки плотно, как в Note Station: у абзацев нет отступов */
  #ed p, #ed div { margin: 0; }
  #ed h1, #ed h2, #ed h3 { margin: .5em 0 .2em; line-height: 1.25; }
  #ed ul, #ed ol { margin: .15em 0; padding-left: 1.6em; }
  #ed li { margin: 0; }
  #ed blockquote { margin: .3em 0; }
  #ed pre { margin: .3em 0; }
  /* Размер как в Note Station: атрибуты width/height; только height — ширина по пропорции */
  img { max-width: 100%; object-fit: contain; }
  img[width] { height: auto; }
  table { border-collapse: collapse; }
  td, th { border: 1px solid rgba(128,128,128,.4); padding: 4px 8px; }
  blockquote { border-left: 3px solid rgba(128,128,128,.5); padding-left: 12px; color: gray; }
  pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 14px; }
  pre { background: rgba(128,128,128,.12); padding: 8px; border-radius: 6px; white-space: pre-wrap; }
  a { color: -apple-system-blue; }

  /* Чекбокс в формате Note Station: <input type="image" class="syno-notestation-editor-checkbox"> */
  #ed input.syno-notestation-editor-checkbox {
    -webkit-appearance: none; appearance: none; box-sizing: border-box;
    width: 16px; height: 16px; margin: 0 6px 0 0; padding: 0; vertical-align: -2px;
    border: 1.5px solid #8e8e93; border-radius: 4px; cursor: pointer;
    background: transparent no-repeat center / 11px 11px; object-position: -999px -999px;
  }
  #ed input.syno-notestation-editor-checkbox-checked {
    background-color: -apple-system-blue; border-color: -apple-system-blue;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 12 12'%3E%3Cpath d='M2 6.5l2.5 2.5L10 3' fill='none' stroke='white' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
  }

  /* Рамка и панель размера картинки — вне #ed, в заметку не попадают */
  #nd-imgsel { position: absolute; display: none; pointer-events: none;
    outline: 2px solid -apple-system-blue; outline-offset: 1px; border-radius: 2px; }
  /* Уголки для изменения размера мышью */
  #nd-imgsel .nd-h { position: absolute; width: 10px; height: 10px; pointer-events: auto; touch-action: none;
    background: white; border: 1.5px solid -apple-system-blue; border-radius: 2px; box-sizing: border-box; }
  #nd-imgsel .nd-h[data-c="nw"] { left: -7px; top: -7px; cursor: nwse-resize; }
  #nd-imgsel .nd-h[data-c="ne"] { right: -7px; top: -7px; cursor: nesw-resize; }
  #nd-imgsel .nd-h[data-c="sw"] { left: -7px; bottom: -7px; cursor: nesw-resize; }
  #nd-imgsel .nd-h[data-c="se"] { right: -7px; bottom: -7px; cursor: nwse-resize; }
  @media (pointer: coarse) {
    #nd-imgsel .nd-h { width: 20px; height: 20px; }
    #nd-imgsel .nd-h[data-c="nw"], #nd-imgsel .nd-h[data-c="sw"] { left: -12px; }
    #nd-imgsel .nd-h[data-c="ne"], #nd-imgsel .nd-h[data-c="se"] { right: -12px; }
    #nd-imgsel .nd-h[data-c="nw"], #nd-imgsel .nd-h[data-c="ne"] { top: -12px; }
    #nd-imgsel .nd-h[data-c="sw"], #nd-imgsel .nd-h[data-c="se"] { bottom: -12px; }
  }
  body.nd-resizing, body.nd-resizing * { cursor: nwse-resize !important; -webkit-user-select: none; }
  #nd-imgbar { position: absolute; display: none; gap: 2px; align-items: center; z-index: 10;
    padding: 4px; border-radius: 10px; background: rgba(250,250,250,.96);
    box-shadow: 0 2px 12px rgba(0,0,0,.18); font: 13px -apple-system, system-ui; -webkit-user-select: none; }
  #nd-imgbar button { border: 0; background: transparent; padding: 4px 9px; border-radius: 6px;
    font: inherit; color: #222; cursor: pointer; min-width: 30px; }
  #nd-imgbar button:hover { background: rgba(0,0,0,.08); }
  #nd-imgbar .nd-sep { width: 1px; align-self: stretch; background: rgba(0,0,0,.15); margin: 2px 4px; }
  #nd-imgbar .nd-size { color: #888; padding: 0 6px; font-variant-numeric: tabular-nums; }
  @media (prefers-color-scheme: dark) {
    #nd-imgbar { background: rgba(50,50,52,.96); }
    #nd-imgbar button { color: #eee; }
    #nd-imgbar button:hover { background: rgba(255,255,255,.12); }
    /* Note Station иногда задаёт цвет текста инлайн — в тёмной теме делаем его читаемым */
    body { background: transparent; color: #e6e6e6; }
    #ed [style*="color: rgb(0, 0, 0)"], #ed [style*="color:#000"], #ed [style*="color: #000"] { color: inherit !important; }
    #ed [style*="background-color: rgb(255, 255, 255)"] { background-color: transparent !important; }
  }
</style>
</head>
<body>
<div id="ed" contenteditable="true" data-placeholder="Текст заметки"></div>
<div id="nd-imgsel"><div class="nd-h" data-c="nw"></div><div class="nd-h" data-c="ne"></div><div class="nd-h" data-c="sw"></div><div class="nd-h" data-c="se"></div></div>
<div id="nd-imgbar" contenteditable="false">
  <button data-a="minus" title="Меньше">−</button>
  <button data-a="plus" title="Больше">+</button>
  <span class="nd-sep"></span>
  <button data-a="0.25">25%</button>
  <button data-a="0.5">50%</button>
  <button data-a="1" title="Исходный размер">100%</button>
  <button data-a="fit" title="По ширине заметки">↔</button>
  <span class="nd-size"></span>
</div>
<script>
(function () {
  const ed = document.getElementById('ed');
  const post = (type, body) => {
    try { window.webkit.messageHandlers.nd.postMessage({ type, body }); } catch (e) {}
  };
  window.addEventListener('error', e => post('log', 'JS error: ' + e.message + ' @' + e.lineno));
  // Новые строки — <p>, как у TinyMCE в Note Station (по умолчанию WebKit делает <div>)
  try { document.execCommand('defaultParagraphSeparator', false, 'p'); } catch (e) {}

  const NS_GIF = 'webman/3rdparty/NoteStation/images/transparent.gif';
  const BLANK = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  const CB = 'syno-notestation-editor-checkbox';
  const CB_ON = 'syno-notestation-editor-checkbox-checked';
  let images = {};
  let timer = null;
  let suppress = false;

  function swapSrc(el, url) {
    if (!el.hasAttribute('data-nd-src')) el.setAttribute('data-nd-src', el.getAttribute('src') || '');
    el.setAttribute('src', url);
  }

  // Показ: картинки — с сервера (или data:-URL до загрузки), чекбоксы — без запроса к NAS.
  function prepare(root) {
    root.querySelectorAll('img[ref]').forEach(img => {
      const url = images[img.getAttribute('ref')];
      if (url) swapSrc(img, url);
    });
    // Старые чекбоксы этого редактора (<input type="checkbox">) — в формат Note Station
    root.querySelectorAll('input[type="checkbox"]').forEach(old => {
      const box = makeCheckbox();
      if (old.checked || old.hasAttribute('checked')) box.classList.add(CB_ON);
      old.replaceWith(box);
    });
    root.querySelectorAll('input.' + CB).forEach(box => {
      if (box.getAttribute('src') !== BLANK) swapSrc(box, BLANK);
    });
  }

  // Вернуть HTML в формате Note Station: подменённые src — обратно.
  function serialize() {
    const clone = ed.cloneNode(true);
    clone.querySelectorAll('[data-nd-src]').forEach(el => {
      el.setAttribute('src', el.getAttribute('data-nd-src'));
      el.removeAttribute('data-nd-src');
    });
    return clone.innerHTML;
  }

  // baseline — HTML сразу после загрузки: открытие заметки без правок не должно
  // считаться изменением (innerHTML нормализует разметку).
  let baseline = '';
  let dragging = false;   // пока тянем уголок картинки — не сохраняем на каждый пиксель
  function changed() {
    if (suppress || dragging) return;
    clearTimeout(timer);
    timer = setTimeout(() => {
      const h = serialize();
      if (h === baseline) return;
      baseline = h;
      post('changed', h);
    }, 400);
  }

  new MutationObserver(list => {
    if (list.every(m => m.type === 'attributes' && m.target === ed)) return;
    changed();
  }).observe(ed, { childList: true, subtree: true, characterData: true, attributes: true });
  ed.addEventListener('input', changed);

  // ---- Строки и чекбоксы ----

  const BLOCK = /^(P|DIV|LI|H[1-6]|BLOCKQUOTE|PRE)$/;

  function currentBlock() {
    const s = window.getSelection();
    if (!s.rangeCount) return null;
    const r = s.getRangeAt(0);
    let n = r.startContainer;
    if (n === ed) n = ed.childNodes[r.startOffset] || ed.lastChild;
    while (n && n !== ed && !(n.nodeType === 1 && BLOCK.test(n.tagName))) n = n.parentNode;
    return (n && n !== ed) ? n : null;
  }

  function makeCheckbox() {
    const box = document.createElement('input');
    box.setAttribute('type', 'image');
    box.setAttribute('src', BLANK);
    box.setAttribute('data-nd-src', NS_GIF);
    box.className = CB;
    return box;
  }

  // Чекбокс в начале строки (как его ищет плагин syno_checkbox в Note Station)
  function leadingCheckbox(el) {
    for (let n = el.firstChild; n; n = n.nextSibling) {
      if (n.nodeType === 3) { if (n.textContent.replace(/[\s ​]/g, '')) return null; continue; }
      if (n.nodeType !== 1) continue;
      if (n.tagName === 'INPUT' && n.classList.contains(CB)) return n;
      if (n.tagName === 'BR') return null;
      if (/^(SPAN|B|STRONG|I|EM|U|S|FONT|STRIKE)$/.test(n.tagName)) return leadingCheckbox(n);
      return null;
    }
    return null;
  }

  function caretAfter(node) {
    const r = document.createRange();
    r.setStartAfter(node);
    r.collapse(true);
    const s = window.getSelection();
    s.removeAllRanges();
    s.addRange(r);
  }

  function toggleCheckboxLine() {
    let block = currentBlock();
    if (!block) { document.execCommand('formatBlock', false, 'p'); block = currentBlock(); }
    if (!block) return;
    const box = leadingCheckbox(block);
    if (box) { box.remove(); if (!block.textContent.trim() && !block.querySelector('img,input')) block.innerHTML = '<br>'; }
    else {
      const nb = makeCheckbox();
      block.insertBefore(nb, block.firstChild);
      if (!block.textContent.replace(/[\s ]/g, '')) caretAfter(nb);
    }
    changed();
  }

  // ---- Блок кода ----
  // Enter внутри <pre> — всегда новая строка в том же блоке (можно делать пустые строки).
  // Выйти из блока: ⌘↩ (Ctrl+Enter), стрелка вниз в конце блока или клик под ним.

  function enclosingPre() {
    const s = window.getSelection();
    if (!s.rangeCount) return null;
    let n = s.getRangeAt(0).startContainer;
    while (n && n !== ed && !(n.nodeType === 1 && n.tagName === 'PRE')) n = n.parentNode;
    return (n && n !== ed) ? n : null;
  }

  function caretAtEnd(pre) {
    const s = window.getSelection();
    const r = s.getRangeAt(0);
    const after = document.createRange();
    after.selectNodeContents(pre);
    after.setStart(r.endContainer, r.endOffset);
    return after.toString().replace(/[\n\u200b]/g, '') === '';
  }

  // Абзац сразу после блока (создаём, если его нет) и курсор в него
  function paragraphAfter(el) {
    let p = el.nextElementSibling;
    if (!p || p.tagName !== 'P') {
      p = document.createElement('p');
      p.innerHTML = '<br>';
      el.after(p);
    }
    const r = document.createRange();
    r.setStart(p, 0);
    r.collapse(true);
    const s = window.getSelection();
    s.removeAllRanges();
    s.addRange(r);
    changed();
  }

  ed.addEventListener('keydown', e => {
    if (e.isComposing) return;
    const pre = enclosingPre();
    if (!pre) return;
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault(); e.stopImmediatePropagation();
      paragraphAfter(pre);
    } else if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault(); e.stopImmediatePropagation();
      document.execCommand('insertLineBreak');
      changed();
    } else if (e.key === 'ArrowDown' && !pre.nextElementSibling && caretAtEnd(pre)) {
      e.preventDefault();
      paragraphAfter(pre);
    }
  }, true);

  // Клик в пустое место под последним блоком кода/таблицей/картинкой — новая строка там
  ed.addEventListener('mousedown', e => {
    if (e.target !== ed) return;
    const last = ed.lastElementChild;
    if (!last || !/^(PRE|TABLE|BLOCKQUOTE|UL|OL)$/.test(last.tagName) && !last.querySelector('img')) return;
    if (e.clientY <= last.getBoundingClientRect().bottom) return;
    e.preventDefault();
    paragraphAfter(last);
  });

  ed.addEventListener('keydown', e => {
    if (e.key !== 'Enter' || e.shiftKey || e.isComposing) return;
    const block = currentBlock();
    const box = block && leadingCheckbox(block);
    if (!box) return;
    if (!block.textContent.replace(/[\s ​]/g, '')) {
      // Enter на пустом пункте — выходим из списка задач: строка становится обычной
      e.preventDefault();
      box.remove();
      if (!block.querySelector('img,input')) block.innerHTML = '<br>';
      changed();
      return;
    }
    // Новая строка тоже начинается с чекбокса. Делаем синхронно, а не после
    // штатного Enter: иначе при быстром наборе чекбокс попадал не в ту строку.
    e.preventDefault();
    document.execCommand('insertParagraph');
    const nb = currentBlock();
    if (nb && nb !== block && !leadingCheckbox(nb)) {
      const fresh = makeCheckbox();
      nb.insertBefore(fresh, nb.firstChild);
      if (!nb.textContent.replace(/[\s ]/g, '')) caretAfter(fresh);
    }
    changed();
  });

  // Клик по чекбоксу — отметить/снять (класс, как в Note Station)
  ed.addEventListener('mousedown', e => {
    if (e.target.tagName === 'INPUT' && e.target.classList.contains(CB)) e.preventDefault();
  });
  ed.addEventListener('click', e => {
    const t = e.target;
    if (t.tagName === 'INPUT' && t.classList.contains(CB)) {
      e.preventDefault();
      t.classList.toggle(CB_ON);
      changed();
    }
  });

  // ---- Вставка ----

  function refFor(name) {
    // Как genUniqueImageRef в Note Station: base64(время + имя файла)
    return btoa(unescape(encodeURIComponent(Date.now() + name)));
  }

  function insertAtCaret(node) {
    const s = window.getSelection();
    let r = s.rangeCount ? s.getRangeAt(0) : null;
    if (!r || !ed.contains(r.commonAncestorContainer)) {
      const p = document.createElement('p');
      ed.appendChild(p);
      r = document.createRange();
      r.selectNodeContents(p);
    }
    r.deleteContents();
    r.insertNode(node);
    caretAfter(node);
  }

  function readAsDataURL(file) {
    return new Promise(res => { const fr = new FileReader(); fr.onload = () => res(fr.result); fr.readAsDataURL(file); });
  }
  function imageSize(url) {
    return new Promise(res => {
      const im = new Image();
      im.onload = () => res([im.naturalWidth, im.naturalHeight]);
      im.onerror = () => res([0, 0]);
      im.src = url;
    });
  }

  async function insertImages(files) {
    for (const f of files) {
      const dataURL = await readAsDataURL(f);
      const ext = (f.type.split('/')[1] || 'png').replace('jpeg', 'jpg');
      const name = (f.name && !/^image\.\w+$/.test(f.name)) ? f.name : ('image-' + Date.now() + '.' + ext);
      const ref = refFor(name);
      images[ref] = dataURL;
      const img = document.createElement('img');
      img.className = 'syno-notestation-image-object';
      img.setAttribute('src', dataURL);
      img.setAttribute('data-nd-src', NS_GIF);
      img.setAttribute('border', '0');
      img.setAttribute('ref', ref);
      let [w, h] = await imageSize(dataURL);
      const maxW = Math.min(ed.clientWidth || 600, 600);
      if (w > maxW && h) {
        h = Math.round(h * maxW / w); w = maxW;
        img.setAttribute('width', w);
        img.setAttribute('height', h);
      }
      img.setAttribute('adjust', 'true');
      // Сначала файл — в Swift, потом правка текста: при отправке картинка уже будет в очереди
      post('image', { ref, name, mime: f.type || 'image/png', data: dataURL.split(',')[1] });
      insertAtCaret(img);
    }
    changed();
  }

  function imageFiles(list) {
    return [...(list || [])].filter(f => f.type && f.type.startsWith('image/'));
  }

  ed.addEventListener('paste', e => {
    const files = imageFiles(e.clipboardData.files);
    if (files.length) {           // картинка из буфера (скриншот, Превью, браузер)
      e.preventDefault();
      insertImages(files);
      return;
    }
    const html = e.clipboardData.getData('text/html');
    if (!html) return;
    // Только безопасный HTML, без скриптов и стилей страницы-источника
    e.preventDefault();
    const doc = new DOMParser().parseFromString(html, 'text/html');
    doc.querySelectorAll('script,style,meta,link,iframe,object').forEach(n => n.remove());
    doc.querySelectorAll('*').forEach(n => {
      [...n.attributes].forEach(a => { if (a.name.startsWith('on')) n.removeAttribute(a.name); });
    });
    document.execCommand('insertHTML', false, doc.body.innerHTML);
  });

  ed.addEventListener('dragover', e => {
    if ([...e.dataTransfer.items].some(i => i.kind === 'file')) e.preventDefault();
  });
  ed.addEventListener('drop', e => {
    const files = imageFiles(e.dataTransfer.files);
    if (!files.length) return;
    e.preventDefault();
    const r = document.caretRangeFromPoint && document.caretRangeFromPoint(e.clientX, e.clientY);
    if (r) { const s = window.getSelection(); s.removeAllRanges(); s.addRange(r); }
    insertImages(files);
  });

  document.addEventListener('selectionchange', () => {
    const s = {};
    ['bold','italic','underline','strikeThrough','insertUnorderedList','insertOrderedList']
      .forEach(c => { try { s[c] = document.queryCommandState(c); } catch (e) {} });
    post('state', s);
  });

  window.nd = {
    load(html, imgs) {
      suppress = true;
      clearTimeout(timer);
      images = imgs || {};
      hideSel();
      ed.innerHTML = html || '';
      prepare(ed);
      baseline = serialize();
      setTimeout(() => { suppress = false; }, 0);
    },
    setImages(imgs) {
      suppress = true;
      images = Object.assign({}, images, imgs || {});
      prepare(ed);
      setTimeout(() => { suppress = false; }, 0);
    },
    setEditable(on) { ed.setAttribute('contenteditable', on ? 'true' : 'false'); },
    exec(cmd, value) {
      ed.focus();
      if (cmd === 'heading') document.execCommand('formatBlock', false, value);
      else if (cmd === 'checkbox') toggleCheckboxLine();
      else if (cmd !== 'focus') document.execCommand(cmd, false, value || null);
      changed();
    },
    // null — правок не было: открытие и закрытие заметки ничего не пишет на сервер
    flush() {
      clearTimeout(timer);
      const h = serialize();
      if (h === baseline) return null;
      baseline = h;
      return h;
    }
  };

  // ---- Размер картинок ----
  // Размер хранится так же, как его пишет сам Note Station: атрибуты width/height у <img>.
  const sel = document.getElementById('nd-imgsel');
  const bar = document.getElementById('nd-imgbar');
  let selImg = null;

  function naturalSize(img) {
    const w = img.naturalWidth || parseInt(img.getAttribute('width')) || img.width;
    const h = img.naturalHeight || parseInt(img.getAttribute('height')) || img.height;
    return { w, h };
  }
  function currentWidth(img) {
    return parseInt(img.getAttribute('width')) || Math.round(img.getBoundingClientRect().width);
  }
  function place() {
    if (!selImg || !document.contains(selImg)) { hideSel(); return; }
    const r = selImg.getBoundingClientRect();
    const x = r.left + window.scrollX, y = r.top + window.scrollY;
    Object.assign(sel.style, { display: 'block', left: x + 'px', top: y + 'px', width: r.width + 'px', height: r.height + 'px' });
    bar.style.display = 'flex';
    const top = y - bar.offsetHeight - 6;
    bar.style.top = (top > window.scrollY ? top : y + 6) + 'px';
    bar.style.left = Math.max(window.scrollX + 4, x) + 'px';
    const n = naturalSize(selImg);
    bar.querySelector('.nd-size').textContent = currentWidth(selImg) + ' × ' +
      Math.round(currentWidth(selImg) * n.h / n.w);
  }
  function hideSel() { selImg = null; sel.style.display = 'none'; bar.style.display = 'none'; }
  function resize(width) {
    if (!selImg) return;
    const n = naturalSize(selImg);
    const w = Math.max(40, Math.min(Math.round(width), ed.clientWidth || width));
    selImg.setAttribute('width', w);
    selImg.setAttribute('height', Math.round(w * n.h / n.w));
    selImg.style.removeProperty('width');
    selImg.style.removeProperty('height');
    if (!selImg.getAttribute('style')) selImg.removeAttribute('style');
    selImg.removeAttribute('adjust');
    place();
    changed();
  }

  ed.addEventListener('click', e => {
    if (e.target.tagName === 'IMG') { selImg = e.target; place(); } else hideSel();
  });

  // Перетаскивание уголка: пропорции сохраняются, ширина — от 40px до ширины заметки
  sel.querySelectorAll('.nd-h').forEach(h => {
    h.addEventListener('pointerdown', e => {
      if (!selImg) return;
      e.preventDefault();
      e.stopPropagation();
      h.setPointerCapture(e.pointerId);
      const c = h.dataset.c;
      const sx = c.includes('e') ? 1 : -1;
      const sy = c.includes('s') ? 1 : -1;
      const startX = e.clientX, startY = e.clientY;
      const r = selImg.getBoundingClientRect();
      const startW = r.width, ratio = r.width / (r.height || 1);
      dragging = true;
      document.body.classList.add('nd-resizing');
      const move = ev => {
        const dx = sx * (ev.clientX - startX);
        const dy = sy * (ev.clientY - startY) * ratio;
        resize(startW + (Math.abs(dx) > Math.abs(dy) ? dx : dy));
      };
      const up = () => {
        h.removeEventListener('pointermove', move);
        h.removeEventListener('pointerup', up);
        h.removeEventListener('pointercancel', up);
        document.body.classList.remove('nd-resizing');
        dragging = false;
        changed();
      };
      h.addEventListener('pointermove', move);
      h.addEventListener('pointerup', up);
      h.addEventListener('pointercancel', up);
    });
  });
  ed.addEventListener('keydown', e => { if (e.key !== 'Enter') hideSel(); });
  window.addEventListener('resize', place);
  bar.addEventListener('mousedown', e => e.preventDefault());   // не терять фокус редактора
  bar.addEventListener('click', e => {
    const b = e.target.closest('button');
    if (!b || !selImg) return;
    const n = naturalSize(selImg);
    const w = currentWidth(selImg);
    switch (b.dataset.a) {
      case 'minus': resize(w * 0.8); break;
      case 'plus': resize(Math.min(w * 1.25, ed.clientWidth)); break;
      case 'fit': resize(ed.clientWidth); break;
      default: resize(n.w * parseFloat(b.dataset.a)); break;
    }
  });

  post('ready', null);
})();
</script>
</body>
</html>
"""#
}
