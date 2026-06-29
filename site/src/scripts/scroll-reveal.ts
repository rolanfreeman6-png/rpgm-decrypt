/**
 * Scroll-reveal: any element with `data-reveal` (or class `.reveal`) starts
 * with reduced opacity + slight Y translate; gets `is-revealed` once it
 * enters the viewport. Single IntersectionObserver handles all of them.
 *
 * No-op for users who prefer-reduced-motion — `.reveal` is left in its
 * final visible state by the global CSS rule.
 */

const targets = document.querySelectorAll<HTMLElement>('[data-reveal], .reveal');
if (targets.length > 0 && 'IntersectionObserver' in window) {
  const io = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-revealed');
          io.unobserve(entry.target);
        }
      }
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0.05 },
  );
  for (const el of targets) {
    // mark expected delay as CSS var so .reveal transition-delay kicks in
    const delay = el.dataset.revealDelay;
    if (delay && !el.style.getPropertyValue('--reveal-delay')) {
      el.style.setProperty('--reveal-delay', `${delay}ms`);
    }
    io.observe(el);
  }
}
