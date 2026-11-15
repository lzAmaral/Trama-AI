(() => {
  'use strict';

  const tabs = Array.from(document.querySelectorAll('[data-demo-tab]'));
  const feedback = document.getElementById('demo-feedback');
  const prompt = document.getElementById('demo-prompt');
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

  function announce(message) {
    if (feedback) feedback.textContent = message;
  }

  function selectTab(name, focus = false) {
    const selected = tabs.find(tab => tab.dataset.demoTab === name);
    if (!selected) return;
    tabs.forEach(tab => {
      const active = tab === selected;
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
      const panel = document.getElementById(tab.getAttribute('aria-controls'));
      if (panel) panel.hidden = !active;
    });
    if (focus) selected.focus();
    const panel = document.getElementById(selected.getAttribute('aria-controls'));
    if (panel && window.gsap && !reducedMotion.matches) {
      gsap.fromTo(panel, { autoAlpha: 0, y: 8 }, {
        autoAlpha: 1, y: 0, duration: 0.24, ease: 'power2.out', overwrite: true,
        clearProps: 'opacity,visibility,transform'
      });
    }
    window.ScrollTrigger?.refresh();
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectTab(tab.dataset.demoTab));
    tab.addEventListener('keydown', event => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      if (event.key === 'ArrowLeft') next = (index + tabs.length - 1) % tabs.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = tabs.length - 1;
      if (next !== undefined) {
        event.preventDefault();
        selectTab(tabs[next].dataset.demoTab, true);
      }
    });
  });

  document.querySelectorAll('[data-demo-action]').forEach(button => {
    button.addEventListener('click', event => {
      event.preventDefault();
      switch (button.dataset.demoAction) {
        case 'attention':
          selectTab('terminal', true);
          announce('Demonstração: a intervenção abre o terminal. No aplicativo, você decide como responder ao CLI.');
          break;
        case 'review':
          selectTab('review', true);
          announce('Demonstração: confira o diff e a nota antes de preparar a revisão.');
          break;
        case 'send':
          if (!prompt?.value.trim()) {
            prompt?.setAttribute('aria-invalid', 'true');
            announce('Escreva uma instrução para experimentar a demonstração.');
            prompt?.focus();
            return;
          }
          prompt.removeAttribute('aria-invalid');
          announce('Instrução simulada. No Trama, o envio acontece ao CLI escolhido. Nenhum agente real foi iniciado aqui.');
          break;
        case 'confirm-review':
          announce('Revisão simulada preparada. No app, você confere a prévia e confirma o envio das notas ao agente.');
          break;
      }
    });
  });

  prompt?.addEventListener('input', () => {
    if (prompt.value.trim() && prompt.hasAttribute('aria-invalid')) {
      prompt.removeAttribute('aria-invalid');
      announce('Instrução pronta para simular. Nenhum comando será executado.');
    }
  });

  const menuToggle = document.querySelector('[data-menu-toggle]');
  const navigation = document.getElementById('site-nav');
  function closeMenu() {
    menuToggle?.setAttribute('aria-expanded', 'false');
    navigation?.setAttribute('data-open', 'false');
  }
  menuToggle?.addEventListener('click', () => {
    const open = menuToggle.getAttribute('aria-expanded') !== 'true';
    menuToggle.setAttribute('aria-expanded', String(open));
    navigation?.setAttribute('data-open', String(open));
  });
  navigation?.querySelectorAll('a').forEach(link => link.addEventListener('click', closeMenu));
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && menuToggle?.getAttribute('aria-expanded') === 'true') {
      closeMenu();
      menuToggle.focus();
    }
  });

  // The page and demonstration remain usable if the animation library fails.
  if (!window.gsap || !window.ScrollTrigger) return;
  gsap.registerPlugin(ScrollTrigger);
  reducedMotion.addEventListener('change', event => {
    if (!event.matches) return;
    gsap.killTweensOf('.demo-panel');
    gsap.set('.demo-panel', { clearProps: 'opacity,visibility,transform' });
  });
  const media = gsap.matchMedia();
  media.add({
    motion: '(prefers-reduced-motion: no-preference)',
    desktop: '(min-width: 901px)'
  }, context => {
    if (!context.conditions.motion) return;
    const desktop = context.conditions.desktop;
    const scrub = 0.45;

    // Scroll owns these timelines in both directions; no scroll interception.
    gsap.from('[data-hero]', {
      opacity: 0, y: 24, stagger: 0.08, duration: 0.7, ease: 'power3.out'
    });
    gsap.to('.reading-progress', {
      scaleX: 1, ease: 'none',
      scrollTrigger: { start: 0, end: 'max', scrub: true }
    });
    document.querySelectorAll('.thread-art [data-thread]').forEach(path => {
      const length = path.getTotalLength();
      gsap.fromTo(path,
        { strokeDasharray: length, strokeDashoffset: length * 0.9 },
        { strokeDashoffset: 0, ease: 'none', scrollTrigger: {
          trigger: '.hero', start: 'top top', end: 'bottom 38%', scrub
        }});
    });
    gsap.to('.thread-art', {
      y: desktop ? 40 : 12, scale: desktop ? 1.04 : 1, ease: 'none',
      scrollTrigger: { trigger: '.hero', start: 'top top', end: 'bottom top', scrub }
    });
    gsap.to('.hero h1 em', {
      x: desktop ? 24 : 0, display: 'inline-block', ease: 'none',
      scrollTrigger: { trigger: '.hero', start: 'top top', end: 'bottom top', scrub }
    });

    const assembly = gsap.timeline({
      defaults: { ease: 'none' },
      scrollTrigger: {
        trigger: '.app-stage', start: 'clamp(top 95%)',
        end: 'clamp(top 28%)', scrub, invalidateOnRefresh: true
      }
    });
    assembly.from('.app-window', {
      scale: desktop ? 0.86 : 0.96, rotationX: desktop ? 9 : 0,
      transformPerspective: 1200, transformOrigin: '50% 0%', y: desktop ? 90 : 25,
      duration: 1
    }, 0).from('.board-column', {
      y: desktop ? 80 : 24, stagger: 0.12, duration: 0.6
    }, 0.15).from('.app-composer', { y: 24, duration: 0.3 }, 0.65);

    // Keyboard users can reach any control before its scroll entrance finishes.
    const appWindow = document.querySelector('.app-window');
    const revealControls = () => {
      assembly.scrollTrigger.disable(false);
      assembly.progress(1);
    };
    const resumeAssembly = event => {
      if (appWindow.contains(event.relatedTarget)) return;
      assembly.scrollTrigger.enable(false, false);
      assembly.scrollTrigger.update();
    };
    appWindow.addEventListener('focusin', revealControls);
    appWindow.addEventListener('focusout', resumeAssembly);
    if (appWindow.contains(document.activeElement)) revealControls();

    document.querySelectorAll('.feature').forEach(feature => {
      gsap.from(feature.querySelector('.feature-visual'), {
        y: desktop ? 48 : 24, ease: 'none',
        scrollTrigger: {
          trigger: feature, start: 'clamp(top 90%)',
          end: 'clamp(top 38%)', scrub
        }
      });
    });

    gsap.fromTo('.flow-progress', { scaleY: 0 }, {
      scaleY: 1, ease: 'none', scrollTrigger: {
        trigger: '.flow-steps', start: 'top 55%', end: 'bottom 55%', scrub
      }
    });
    document.querySelectorAll('.flow-steps > li').forEach(step => {
      gsap.from(step.querySelector('div'), {
        x: desktop ? 24 : 0, y: desktop ? 0 : 24, ease: 'none',
        scrollTrigger: { trigger: step, start: 'top 82%', end: 'top 42%', scrub }
      });
      gsap.fromTo(step.querySelector('.step-number'),
        { scale: 0.9, color: '#64736d' },
        { scale: 1.1, color: '#217360', ease: 'none', scrollTrigger: {
          trigger: step, start: 'top 72%', end: 'top 42%', scrub
        }});
    });
    document.querySelectorAll('.flow-decoration path').forEach(path => {
      const length = path.getTotalLength();
      gsap.fromTo(path, { strokeDasharray: length, strokeDashoffset: length }, {
        strokeDashoffset: 0, ease: 'none', scrollTrigger: {
          trigger: '.flow-steps', start: 'top 65%', end: 'bottom 65%', scrub
        }
      });
    });
    gsap.from('.final-cta h2', {
      y: 45, scale: 0.92, transformOrigin: 'left center', ease: 'none',
      scrollTrigger: { trigger: '.final-cta', start: 'top 95%', end: 'top 40%', scrub }
    });
    return () => {
      appWindow.removeEventListener('focusin', revealControls);
      appWindow.removeEventListener('focusout', resumeAssembly);
    };
  });
  document.fonts?.ready.then(() => ScrollTrigger.refresh());
  document.querySelectorAll('details').forEach(item => {
    item.addEventListener('toggle', () => ScrollTrigger.refresh());
  });
})();
