document.addEventListener('DOMContentLoaded', function () {
  // ---- NieR menu-rail inversion ----
  document.querySelectorAll('[data-menu]').forEach(m => {
    const chev = m.querySelector('span:last-child');
    m.style.transition = 'background .18s ease, color .18s ease, padding-left .18s ease';
    m.addEventListener('mouseenter', () => {
      if (m.dataset.selected) return;
      m.style.background = '#454135'; m.style.color = '#CAC4AE';
      m.style.paddingLeft = '20px';
      if (chev) chev.style.opacity = '1';
    });
    m.addEventListener('mouseleave', () => {
      if (m.dataset.selected) return;
      m.style.background = 'transparent'; m.style.color = '#454135';
      m.style.paddingLeft = '14px';
      if (chev) chev.style.opacity = '0';
    });
  });

  // ---- work cards: lift + border on hover ----
  document.querySelectorAll('[data-card]').forEach(card => {
    card.addEventListener('mouseenter', () => {
      card.style.transform = 'translateY(-3px)';
      card.style.borderColor = '#454135';
    });
    card.addEventListener('mouseleave', () => {
      card.style.transform = 'none';
      card.style.borderColor = '#6F6B57';
    });
  });

  // ---- CTA + link hover ----
  document.querySelectorAll('[data-cta]').forEach(c => {
    c.style.transition = 'transform .18s ease, opacity .18s ease';
    c.addEventListener('mouseenter', () => { c.style.transform = 'translateY(-2px)'; c.style.opacity = '0.9'; });
    c.addEventListener('mouseleave', () => { c.style.transform = 'none'; c.style.opacity = '1'; });
  });
  document.querySelectorAll('[data-link]').forEach(l => {
    l.style.transition = 'opacity .18s ease';
    l.addEventListener('mouseenter', () => l.style.opacity = '0.55');
    l.addEventListener('mouseleave', () => l.style.opacity = '1');
  });
});