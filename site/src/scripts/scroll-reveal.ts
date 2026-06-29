/**
 * Two responsibilities, one observer:
 *   1. Reveal any element with `data-reveal` (or class `.reveal`) as it
 *      enters the viewport. Stagger via `data-reveal-delay`.
 *   2. Mark any element with class `scene` as `.is-active` once it crosses
 *      a 25% threshold — this fires CSS transitions on `.scene__content`
 *      (used by the home page for full-viewport snap scenes).
 *
 * No-op for users who prefer-reduced-motion: scenes and `.reveal` are kept
 * in their final visible state by the matching CSS rules.
 */

const targets = document.querySelectorAll<HTMLElement>('[data-reveal], .reveal');
const scenes  = document.querySelectorAll<HTMLElement>('.scene');

if (targets.length > 0 || scenes.length > 0) {
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const el = entry.target as HTMLElement;

          if (el.classList.contains('scene')) {
            el.classList.add('is-active');
          } else {
            // mark expected delay as CSS var so .reveal transition-delay kicks in
            const delay = el.dataset.revealDelay;
            if (delay && !el.style.getPropertyValue('--reveal-delay')) {
              el.style.setProperty('--reveal-delay', `${delay}ms`);
            }
            el.classList.add('is-revealed');
          }
          io.unobserve(el);
        }
      },
      { rootMargin: '0px 0px -8% 0px', threshold: 0.18 },
    );

    for (const el of targets) io.observe(el);
    for (const el of scenes)  io.observe(el);
  } else {
    // Fallback — show everything immediately.
    for (const el of targets) el.classList.add('is-revealed');
    for (const el of scenes)  el.classList.add('is-active');
  }
}
