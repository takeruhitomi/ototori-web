/*
 * A small progress strip over the app (the Android build shows recognition
 * progress in a notification). Purely visual; it never takes input.
 */
let box = null;

function ensure() {
  if (box) return box;
  box = document.createElement('div');
  box.setAttribute('role', 'status');
  box.style.cssText = [
    'position:fixed', 'left:50%', 'transform:translateX(-50%)', 'top:calc(8px + env(safe-area-inset-top))', // the app's own bars are at the bottom
    'z-index:2147483647', 'pointer-events:none', 'max-width:min(92vw,520px)', 'box-sizing:border-box',
    'padding:10px 14px', 'border-radius:12px', 'background:rgba(20,26,60,.92)', 'color:#fff',
    'font:13px/1.4 -apple-system,"Hiragino Sans","Noto Sans JP",sans-serif', 'box-shadow:0 4px 16px rgba(0,0,0,.25)',
  ].join(';');
  box.innerHTML = '<div class="t"></div><div style="margin-top:6px;height:4px;border-radius:2px;background:rgba(255,255,255,.25);overflow:hidden"><div class="b" style="height:100%;width:0;background:#E7C66B;transition:width .2s"></div></div>';
  return box;
}

export function showProgress(text, fraction) {
  const el = ensure();
  if (!el.isConnected) document.body.appendChild(el);
  el.querySelector('.t').textContent = text;
  el.querySelector('.b').style.width = `${Math.max(0, Math.min(1, fraction || 0)) * 100}%`;
}

export function hideProgress() { box?.remove(); }
