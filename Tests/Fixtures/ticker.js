// Tiny GSAP-like ticker (no GSAP): rAF + performance.now, with GSAP's default lag smoothing (500ms -> 33ms).
(function(){
  const tweens=[]; let last=performance.now(), time=0;
  function tick(){
    const n=performance.now(); let dt=n-last; last=n;
    if(dt>500) dt=33;            // lagSmoothing(500,33)
    time+=dt;
    for(const tw of tweens){
      const p=Math.min(1,Math.max(0,(time-tw.delay)/tw.dur));
      tw.el.style.transform='translateX('+(tw.from+(tw.to-tw.from)*p)+'px)';
    }
    requestAnimationFrame(tick);
  }
  window.ticker={ to(el,from,to,durMs,delayMs){tweens.push({el,from,to,dur:durMs,delay:delayMs||0})}, get time(){return time} };
  requestAnimationFrame(tick);
})();
