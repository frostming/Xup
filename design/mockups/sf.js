/* 用内联 SVG 近似 SF Symbols；每个 <i class="sf" data-sf="name"> 会被替换为近似图形，并带 title 以便开发查看 symbol 名称。 */
(function(){
  const C = (inner, vb='0 0 24 24') => `<svg viewBox="${vb}" xmlns="http://www.w3.org/2000/svg">${inner}</svg>`;
  const circle = '<circle cx="12" cy="12" r="10"/>';
  const circleO = '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8"/>';
  const S = {
    'arrow.up.circle.fill': C(circle+'<path d="M12 6.5l-5 5 1.4 1.4L11 10.3V18h2v-7.7l2.6 2.6L17 11.5z" fill="#fff"/>'),
    'arrow.up.circle': C(circleO+'<path d="M12 6.5l-5 5 1.4 1.4L11 10.3V18h2v-7.7l2.6 2.6L17 11.5z"/>'),
    'checkmark.circle.fill': C(circle+'<path d="M7 12.5l3 3 7-7" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'checkmark.circle': C(circleO+'<path d="M7 12.5l3 3 7-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'checkmark.seal.fill': C('<path d="M12 2l2.2 1.8 2.8-.5 1 2.7 2.7 1-.5 2.8L22 12l-1.8 2.2.5 2.8-2.7 1-1 2.7-2.8-.5L12 22l-2.2-1.8-2.8.5-1-2.7-2.7-1 .5-2.8L2 12l1.8-2.2-.5-2.8 2.7-1 1-2.7 2.8.5z"/><path d="M7.5 12.5l3 3 6.5-6.5" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'xmark.circle.fill': C(circle+'<path d="M8.5 8.5l7 7M15.5 8.5l-7 7" stroke="#fff" stroke-width="2.2" stroke-linecap="round"/>'),
    'questionmark.circle': C(circleO+'<path d="M9.5 9.5a2.5 2.5 0 1 1 3.6 2.2c-.8.4-1.1.9-1.1 1.8" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/><circle cx="12" cy="17" r="1.1"/>'),
    'exclamationmark.triangle.fill': C('<path d="M12 3l10 18H2z"/><path d="M12 9v5" stroke="#fff" stroke-width="2.2" stroke-linecap="round"/><circle cx="12" cy="17.2" r="1.2" fill="#fff"/>'),
    'exclamationmark.triangle': C('<path d="M12 4l9 16H3z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M12 9.5v4.5" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/><circle cx="12" cy="17" r="1.1"/>'),
    'exclamationmark.circle': C(circleO+'<path d="M12 7.5v5.5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="16.5" r="1.2"/>'),
    'pin.fill': C('<path d="M14 2l8 8-3 1-3.5 3.5.5 4.5L13.5 21 9 16.5 3.5 22 2 20.5 7.5 15 3 10.5l1.9-2.5 4.6.5L13 5z"/>'),
    'arrow.clockwise': C('<path d="M19 12a7 7 0 1 1-2.2-5.1" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="M17 2.5v5h-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'arrow.counterclockwise': C('<path d="M5 12a7 7 0 1 0 2.2-5.1" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="M7 2.5v5h5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'arrow.down.circle': C(circleO+'<path d="M12 17.5l5-5-1.4-1.4L13 13.7V6h-2v7.7L8.4 11.1 7 12.5z"/>'),
    'arrow.down.to.line': C('<path d="M12 3v12M6.5 9.5L12 15l5.5-5.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/><path d="M5 20h14" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>'),
    'arrow.down.to.line.compact': C('<path d="M12 5v10M7 10l5 5 5-5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/><path d="M6 19h12" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>'),
    'arrow.triangle.2.circlepath': C('<path d="M20 11a8 8 0 0 0-14-4M4 13a8 8 0 0 0 14 4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><path d="M6 3v4.5h4.5M18 21v-4.5h-4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'stop.circle': C(circleO+'<rect x="8.5" y="8.5" width="7" height="7" rx="1"/>'),
    'plus': C('<path d="M12 4v16M4 12h16" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/>'),
    'minus': C('<path d="M4 12h16" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"/>'),
    'trash': C('<path d="M4 7h16M9 7V4.5h6V7M6.5 7l1 13h9l1-13" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'),
    'terminal': C('<rect x="3" y="4.5" width="18" height="15" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M7 9l3 3-3 3M12 15h5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>'),
    'doc.on.doc': C('<rect x="8" y="3" width="12" height="15" rx="2" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M5 8v11a2 2 0 0 0 2 2h9" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>'),
    'folder': C('<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h5l2 2h8A1.5 1.5 0 0 1 21 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z" fill="none" stroke="currentColor" stroke-width="1.8"/>'),
    'square.and.pencil': C('<path d="M12 5H6a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M18.5 3.5l2 2L13 13l-3 1 1-3z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>'),
    'info.circle': C(circleO+'<path d="M12 11v6" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="7.8" r="1.2"/>'),
    'magnifyingglass': C('<circle cx="10.5" cy="10.5" r="6.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M15.5 15.5L21 21" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>'),
    'macwindow': C('<rect x="3" y="4.5" width="18" height="15" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M3 9h18" stroke="currentColor" stroke-width="1.8"/>'),
    'macwindow.badge.plus': C('<rect x="3" y="4.5" width="18" height="15" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M3 9h18" stroke="currentColor" stroke-width="1.8"/><circle cx="18.5" cy="17.5" r="4.5"/><path d="M18.5 15v5M16 17.5h5" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/>'),
    'gearshape': C('<path d="M12 2.5l2 .4.5 2.2 2 .9 1.9-1.2 1.5 1.5-1.2 1.9.9 2 2.2.5.4 2-2.2 1.3-.4 2.1 1 2-1.5 1.5-2-1-1.9 1-.7 2.2-2.1.2-1.3-1.9-2.2.1-1.3 1.8-2-.6-.3-2.2-1.9-1.2L2.5 15l.2-2.1-1.6-1.6 1.1-1.8 2.2-.3.9-2L4.2 5.4 5.7 3.9l1.9 1.1 2.1-.8.3-2.2z" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/><circle cx="12" cy="12" r="3.2" fill="none" stroke="currentColor" stroke-width="1.6"/>'),
    'cpu': C('<rect x="6" y="6" width="12" height="12" rx="2" fill="none" stroke="currentColor" stroke-width="1.8"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/><path d="M9 2.5v3M12 2.5v3M15 2.5v3M9 18.5v3M12 18.5v3M15 18.5v3M2.5 9h3M2.5 12h3M2.5 15h3M18.5 9h3M18.5 12h3M18.5 15h3" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>'),
    'mug': C('<path d="M4 6h11v9a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M15 8.5h2.5a2.5 2.5 0 0 1 0 5H15" fill="none" stroke="currentColor" stroke-width="1.8"/>'),
    'shippingbox': C('<path d="M3 8l9-4.5L21 8v8l-9 4.5L3 16z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M3 8l9 4.5L21 8M12 12.5v8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>'),
    'bolt': C('<path d="M13.5 2L5 13.5h6l-1 8.5 9-12h-6z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>'),
    'square.grid.2x2': C('<rect x="3.5" y="3.5" width="7.5" height="7.5" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.8"/><rect x="13" y="3.5" width="7.5" height="7.5" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.8"/><rect x="3.5" y="13" width="7.5" height="7.5" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.8"/><rect x="13" y="13" width="7.5" height="7.5" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.8"/>'),
    'questionmark.folder': C('<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h5l2 2h8A1.5 1.5 0 0 1 21 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M10.2 11.3a1.9 1.9 0 1 1 2.7 1.7c-.6.3-.9.7-.9 1.4" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/><circle cx="12" cy="16.6" r=".9"/>'),
    'power': C('<path d="M12 3v8" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/><path d="M7 6.5a7.5 7.5 0 1 0 10 0" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>'),
    'sidebar.left': C('<rect x="3" y="4.5" width="18" height="15" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M9 4.5v15" stroke="currentColor" stroke-width="1.8"/>'),
    'chevron.right': C('<path d="M9 5l7 7-7 7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'arrow.right': C('<path d="M4 12h15M13 6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'sparkles': C('<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M19 15l.9 2.1L22 18l-2.1.9L19 21l-.9-2.1L16 18l2.1-.9z"/><path d="M5 15l.7 1.6L7.3 17.3l-1.6.7L5 19.6l-.7-1.6-1.6-.7 1.6-.7z"/>'),
    'puzzlepiece.extension': C('<path d="M9 4.5a2 2 0 1 1 4 0V6h4a1.5 1.5 0 0 1 1.5 1.5V11h-1.5a2 2 0 1 0 0 4H18v3.5A1.5 1.5 0 0 1 16.5 20H13v-1.5a2 2 0 1 0-4 0V20H5.5A1.5 1.5 0 0 1 4 18.5V15h1.5a2 2 0 1 0 0-4H4V7.5A1.5 1.5 0 0 1 5.5 6H9z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>'),
    'checklist': C('<path d="M3.5 6.5l1.5 1.5 3-3M3.5 12.5l1.5 1.5 3-3M3.5 18.5l1.5 1.5 3-3" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/><path d="M11 6.5h10M11 12.5h10M11 18.5h10" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>'),
    'eye.slash': C('<path d="M3 12s3.5-6 9-6 9 6 9 6-3.5 6-9 6-9-6-9-6z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><circle cx="12" cy="12" r="2.8" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="M4 20L20 4" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'),
    'icloud': C('<path d="M7 18.5a4 4 0 0 1-.6-7.95A5.5 5.5 0 0 1 17 9.2 3.8 3.8 0 0 1 17.5 18.5z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/>'),
    'clock.arrow.circlepath': C(circleO+'<path d="M12 7.5V12l3 2" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>'),
    'xmark.circle': C(circleO+'<path d="M8.5 8.5l7 7M15.5 8.5l-7 7" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>'),
    'safari': C(circleO+'<path d="M15.5 8.5l-2.2 5-5 2.2 2.2-5z"/><path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>'),
    'play.circle': C(circleO+'<path d="M10 8.3v7.4l5.8-3.7z"/>'),
    'play.fill': C('<path d="M7 4.5v15l12-7.5z"/>'),
    'slider.horizontal.3': C('<path d="M3 7h18M3 12h18M3 17h18" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><circle cx="9" cy="7" r="2.2" fill="var(--bg-content,#fff)" stroke="currentColor" stroke-width="1.8"/><circle cx="15" cy="12" r="2.2" fill="var(--bg-content,#fff)" stroke="currentColor" stroke-width="1.8"/><circle cx="7" cy="17" r="2.2" fill="var(--bg-content,#fff)" stroke="currentColor" stroke-width="1.8"/>'),
    'link': C('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1.2 1.2M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1.2-1.2" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/>'),
    'chevron.down': C('<path d="M5 9l7 7 7-7" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'),
    'doc.text': C('<path d="M6 3h8l5 5v13H6z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M14 3v5h5M9 12h7M9 16h7" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>'),
    'arrow.down.circle.fill': C(circle+'<path d="M12 17.5l5-5-1.4-1.4L13 13.7V6h-2v7.7L8.4 11.1 7 12.5z" fill="#fff"/>'),
    'arrow.down.circle.dotted': C('<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="1.8" stroke-dasharray="2.4 2.6"/><path d="M12 17.5l5-5-1.4-1.4L13 13.7V6h-2v7.7L8.4 11.1 7 12.5z"/>'),
    'checkmark': C('<path d="M5 12.5l4.5 4.5L19 7" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>'),
    'hand.raised': C('<path d="M8 12V5.5a1.5 1.5 0 0 1 3 0V11M11 11V4a1.5 1.5 0 0 1 3 0v7M14 11V5.5a1.5 1.5 0 0 1 3 0V13M17 13v-1.5a1.5 1.5 0 0 1 3 0V15a7 7 0 0 1-7 7h-1.5a6 6 0 0 1-5-2.7L3.6 14.4a1.6 1.6 0 0 1 2.6-1.8L8 15" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/>'),
    'moon.zzz': C('<path d="M13.5 3a8.5 8.5 0 1 0 7.5 12.5A7 7 0 0 1 13.5 3z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M15 5h4l-4 4h4M18.5 11h2.5l-2.5 2.5H21" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>'),
    'bell.badge': C('<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M10 20a2 2 0 0 0 4 0" fill="none" stroke="currentColor" stroke-width="1.8"/><circle cx="18" cy="6" r="3"/>'),
  };
  document.querySelectorAll('i.sf[data-sf]').forEach(el => {
    const n = el.dataset.sf;
    el.innerHTML = S[n] || C('<rect x="4" y="4" width="16" height="16" rx="3" fill="none" stroke="currentColor" stroke-dasharray="2 2"/>');
    el.title = 'SF Symbol: ' + n;
  });
  // 主题切换
  const saved = localStorage.getItem('xup-theme');
  if (saved === 'dark') document.body.classList.add('dark');
  const btn = document.getElementById('theme');
  const sync = () => { if (btn) btn.textContent = document.body.classList.contains('dark') ? '切换到浅色' : '切换到深色'; };
  if (btn) btn.onclick = () => { document.body.classList.toggle('dark'); localStorage.setItem('xup-theme', document.body.classList.contains('dark') ? 'dark' : 'light'); sync(); };
  sync();
})();
