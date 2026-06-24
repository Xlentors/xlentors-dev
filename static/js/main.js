document.addEventListener('DOMContentLoaded', function () {
  const menuItems = document.querySelectorAll('[data-menu]');

  function setActive(target) {
    menuItems.forEach(m => {
      const chev = m.querySelector('span:last-child');
      const isTarget = m.dataset.target === target;
      delete m.dataset.selected;
      if (isTarget) {
        m.dataset.selected = '1';
        m.style.background = '#454135';
        m.style.color = '#CAC4AE';
        m.style.paddingLeft = '14px';
        if (chev) chev.style.opacity = '1';
      } else {
        m.style.background = 'transparent';
        m.style.color = '#454135';
        m.style.paddingLeft = '14px';
        if (chev) chev.style.opacity = '0';
      }
    });
  }

  function scrollTo(id) {
    const el = document.getElementById(id);
    if (!el) return;
    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  // ---- menu rail: hover + click ----
  menuItems.forEach(m => {
    const chev = m.querySelector('span:last-child');
    m.style.transition = 'background .18s ease, color .18s ease, padding-left .18s ease';

    m.addEventListener('mouseenter', () => {
      if (m.dataset.selected) return;
      m.style.background = '#454135';
      m.style.color = '#CAC4AE';
      m.style.paddingLeft = '20px';
      if (chev) chev.style.opacity = '1';
    });
    m.addEventListener('mouseleave', () => {
      if (m.dataset.selected) return;
      m.style.background = 'transparent';
      m.style.color = '#454135';
      m.style.paddingLeft = '14px';
      if (chev) chev.style.opacity = '0';
    });
    m.addEventListener('click', () => {
      const target = m.dataset.target;
      if (!target) return;
      setActive(target);
      scrollTo(target);
    });
  });

  // ---- inline scroll buttons (VIEW WORK, Contact) ----
  document.querySelectorAll('[data-scroll]').forEach(el => {
    el.addEventListener('click', () => {
      const target = el.dataset.scroll;
      setActive(target);
      scrollTo(target);
    });
  });

  // ---- scroll spy ----
  const sections = ['home', 'work', 'capabilities', 'about', 'contact'];
  const observers = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (entry.isIntersecting) {
        setActive(entry.target.id);
      }
    });
  }, { rootMargin: '-40% 0px -55% 0px', threshold: 0 });

  sections.forEach(id => {
    const el = document.getElementById(id);
    if (el) observers.observe(el);
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
