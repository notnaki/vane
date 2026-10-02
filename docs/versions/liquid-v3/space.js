(() => {
  'use strict';

  // Seeded geometry keeps each scene stable across resize and page navigation.
  function random(seed) {
    return () => {
      seed |= 0;
      seed = seed + 0x6D2B79F5 | 0;
      let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }
  function sizeCanvas(canvas) {
    const box = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(box.width * dpr);
    canvas.height = Math.round(box.height * dpr);
    const ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { ctx, width: box.width, height: box.height };
  }
  function drawStars(ctx, width, height, seed, density = 2600) {
    const rng = random(seed);
    const count = Math.min(800, Math.floor(width * height / density));
    for (let i = 0; i < count; i++) {
      const x = rng() * width, y = rng() * height;
      const radius = .35 + rng() * .8;
      ctx.fillStyle = `rgba(184,205,230,${.16 + rng() * .45})`;
      ctx.beginPath(); ctx.arc(x, y, radius, 0, Math.PI * 2); ctx.fill();
      if (i % 37 === 0) {
        const glow = ctx.createRadialGradient(x, y, 0, x, y, 7);
        glow.addColorStop(0, 'rgba(205,225,248,.2)'); glow.addColorStop(1, 'rgba(180,210,245,0)');
        ctx.fillStyle = glow; ctx.fillRect(x - 7, y - 7, 14, 14);
      }
    }
  }

  const background = document.createElement('canvas');
  background.className = 'space-background';
  background.setAttribute('aria-hidden', 'true');
  document.body.prepend(background);
  function drawBackground() {
    const surface = sizeCanvas(background);
    if (surface) drawStars(surface.ctx, surface.width, surface.height, 2026, 3200);
  }
  drawBackground();

  // Lit point clouds and front/back ring passes give the small studies real volume.
  function drawOrbit(canvas) {
    const surface = sizeCanvas(canvas);
    if (!surface) return;
    const { ctx, width, height } = surface;
    const variant = Number(canvas.dataset.orbit);
    const rng = random(92 + variant);
    const palette = ['180,211,249', '238,213,167', '205,195,236'][variant];
    const radius = Math.min(height * .32, width * .24);
    const cx = width / 2, cy = height / 2;
    const tilt = [-.35, .26, -.58][variant];
    const ring = Array.from({length:1900}, () => {
      const a = rng() * Math.PI * 2;
      const r = radius * (1.5 + rng() * .42);
      return {x:Math.cos(a)*r,y:Math.sin(a)*r*.28,alpha:.25+rng()*.6};
    });
    const drawRing = front => {
      for (const p of ring) {
        if ((p.y > 0) !== front) continue;
        const x = cx + p.x * Math.cos(tilt) - p.y * Math.sin(tilt);
        const y = cy + p.x * Math.sin(tilt) + p.y * Math.cos(tilt);
        ctx.fillStyle=`rgba(${palette},${p.alpha*(front?1:.55)})`;
        ctx.fillRect(x,y,.7,.7);
      }
    };
    drawRing(false);
    const halo = ctx.createRadialGradient(cx,cy,0,cx,cy,radius*1.3);
    halo.addColorStop(0,`rgba(${palette},.07)`); halo.addColorStop(1,`rgba(${palette},0)`);
    ctx.fillStyle=halo; ctx.fillRect(cx-radius*1.3,cy-radius*1.3,radius*2.6,radius*2.6);
    for (let i = 0; i < 3600; i++) {
      const y = 1 - 2 * i / 3599;
      const r = Math.sqrt(1 - y * y);
      const angle = i * 2.3999632297 + variant;
      const x = Math.cos(angle) * r, z = Math.sin(angle) * r;
      if (z < 0) continue;
      const light = Math.max(.12, x * -.35 + y * -.45 + z * .85);
      const texture = .74 + .26 * Math.sin(x*12+Math.sin(y*9)+variant);
      ctx.fillStyle=`rgba(${palette},${Math.min(1,light*texture)})`;
      ctx.fillRect(cx+x*radius,cy+y*radius,.85,.85);
    }
    drawRing(true);
  }
  const orbitCanvases = [...document.querySelectorAll('[data-orbit]')];
  orbitCanvases.forEach(drawOrbit);

  const clamp = (v, lo = 0, hi = 1) => Math.max(lo, Math.min(hi, v));
  const ease = v => { v = clamp(v); return v * v * (3 - 2 * v); };
  function cameraGeometry({width, height}, camera) {
    const radius = Math.min(width * .47, height * .53) * camera.zoom;
    return {radius, cx: width * camera.ax - camera.x * radius, cy: height * camera.ay - camera.y * radius};
  }

  // Additive point sprites: a sharp stellar core with a separate, restrained bloom pass.
  function createGalaxyRenderer(canvas, particles) {
    const gl = canvas.getContext('webgl', { alpha: true, antialias: false, premultipliedAlpha: true, powerPreference: 'low-power' });
    if (!gl) return null;
    const vertexSource = `
      attribute vec3 a_position;
      attribute float a_size;
      attribute vec3 a_color;
      attribute float a_brightness;
      attribute float a_kind;
      uniform vec2 u_resolution;
      uniform vec2 u_center;
      uniform float u_radius;
      uniform float u_angle;
      uniform float u_tilt;
      uniform float u_dpr;
      uniform float u_time;
      uniform float u_bloom;
      uniform float u_flow;
      varying vec3 v_color;
      varying float v_brightness;
      void main() {
        float ca = cos(u_angle), sa = sin(u_angle);
        float ct = cos(u_tilt), st = sin(u_tilt);
        vec3 p = a_position;
        if (a_kind > 0.5) {
          float r = length(p.xy);
          p.xy += vec2(sin(p.y * 6.0 + u_flow), sin(p.x * 5.0 - u_flow)) * r * 0.065;
        }
        float x = p.x * ca - p.y * sa;
        float y = p.x * sa + p.y * ca;
        float depth = y * st + p.z * ct;
        float perspective = 1.0 / (1.0 + depth * 0.22);
        vec2 pixel = u_center + vec2(x, y * ct - p.z * st) * u_radius * perspective;
        float size = max(1.1, a_size * u_radius / 300.0 * perspective);
        if (a_kind < 0.5) { pixel = p.xy * u_resolution; size = a_size; }
        gl_Position = vec4(pixel.x / u_resolution.x * 2.0 - 1.0, 1.0 - pixel.y / u_resolution.y * 2.0, 0.0, 1.0);
        gl_PointSize = size * u_dpr * mix(3.0, 14.0, u_bloom);
        v_color = a_color;
        float scintillation = 0.96 + 0.04 * sin(u_time * 0.0003 + p.x * 93.0 + p.y * 71.0);
        v_brightness = a_brightness * scintillation;
        if (u_bloom > 0.5) v_brightness *= smoothstep(0.75, 2.4, a_size) * 0.13;
      }
    `;
    const fragmentSource = `
      precision mediump float;
      varying vec3 v_color;
      varying float v_brightness;
      uniform float u_bloom;
      void main() {
        vec2 uv = gl_PointCoord * 2.0 - 1.0;
        float radius = dot(uv, uv);
        if (radius > 1.0) discard;
        float intensity = exp(-radius * mix(7.5, 4.0, u_bloom));
        float alpha = intensity * v_brightness;
        gl_FragColor = vec4(v_color * alpha, alpha);
      }
    `;
    const compile = (type, source) => {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source); gl.compileShader(shader);
      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) { gl.deleteShader(shader); return null; }
      return shader;
    };
    const vertex = compile(gl.VERTEX_SHADER, vertexSource), fragment = compile(gl.FRAGMENT_SHADER, fragmentSource);
    if (!vertex || !fragment) return null;
    const program = gl.createProgram(); gl.attachShader(program, vertex); gl.attachShader(program, fragment); gl.linkProgram(program);
    gl.deleteShader(vertex); gl.deleteShader(fragment);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
    gl.useProgram(program);
    const data = new Float32Array(particles.length * 9);
    particles.forEach((p, i) => data.set([p.x, p.y, p.z, p.size, ...p.rgb, p.brightness, p.kind], i * 9));
    const buffer = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buffer); gl.bufferData(gl.ARRAY_BUFFER, data, gl.STATIC_DRAW);
    for (const [name, size, offset] of [['a_position',3,0],['a_size',1,3],['a_color',3,4],['a_brightness',1,7],['a_kind',1,8]]) {
      const location = gl.getAttribLocation(program, name);
      gl.enableVertexAttribArray(location); gl.vertexAttribPointer(location, size, gl.FLOAT, false, 36, offset * 4);
    }
    const uniforms = Object.fromEntries(['resolution','center','radius','angle','tilt','dpr','time','bloom','flow'].map(name => [name,gl.getUniformLocation(program,'u_'+name)]));
    gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE); gl.disable(gl.DEPTH_TEST);
    const resize = () => {
      const rect = canvas.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(rect.width * dpr); canvas.height = Math.round(rect.height * dpr);
      gl.viewport(0, 0, canvas.width, canvas.height);
      return {width: rect.width, height: rect.height, dpr};
    };
    return {
      resize,
      draw({width,height,dpr}, angle, tilt, time, camera, flow) {
        const {radius,cx,cy} = cameraGeometry({width,height},camera);
        gl.clearColor(0,0,0,0); gl.clear(gl.COLOR_BUFFER_BIT);
        gl.uniform2f(uniforms.resolution,width,height);
        gl.uniform2f(uniforms.center,cx,cy);
        gl.uniform1f(uniforms.radius,radius); gl.uniform1f(uniforms.flow,flow);
        gl.uniform1f(uniforms.angle,angle); gl.uniform1f(uniforms.tilt,tilt); gl.uniform1f(uniforms.dpr,dpr); gl.uniform1f(uniforms.time,time);
        gl.uniform1f(uniforms.bloom,1); gl.drawArrays(gl.POINTS,0,particles.length);
        gl.uniform1f(uniforms.bloom,0); gl.drawArrays(gl.POINTS,0,particles.length);
      }
    };
  }

  const canvas = document.querySelector('[data-galaxy="hero"]');
  let resizeHero = () => {};
  if (canvas) {
    const rng = random(61026);
    const particles = [];
    const gaussian = () => Math.sqrt(-2 * Math.log(Math.max(.0001, rng()))) * Math.cos(2 * Math.PI * rng());
    const palette = [[.64,.77,1],[.92,.93,1],[.82,.68,1]];
    const count = window.innerWidth < 600 ? 9500 : 18000;
    for (let i = 0; i < count; i++) {
      const core = i < count * .14;
      const diffuse = !core && rng() < .28;
      const r = core ? Math.abs(gaussian()) * .125 : .055 + Math.pow(rng(), .82) * .945;
      const arm = i % 2;
      const spread = .035 + r * .085;
      const a = core || diffuse ? rng() * Math.PI * 2 : arm * Math.PI + r * 8.4 + gaussian() * spread;
      const clump = 1 + .065 * Math.sin(r * 17 + arm);
      const bright = Math.pow(rng(), 7);
      const rgb = palette[rng() < .15 ? 2 : rng() < .6 ? 0 : 1];
      particles.push({x: Math.cos(a) * r * clump, y: Math.sin(a) * r * clump, z: gaussian() * (core ? .045 : .009 + r * .02), size: .28 + bright * 3.1, rgb, brightness: (core ? .28 : diffuse ? .18 : .42) + bright * .45, kind: 1});
    }
    for (let i = 0; i < 450; i++) particles.push({x:rng(),y:rng(),z:0,size:.45 + Math.pow(rng(),8) * 1.8,rgb:palette[0],brightness:.12+rng()*.4,kind:0});
    const glowSprites = palette.map(rgb => {
      const sprite = document.createElement('canvas'); sprite.width = sprite.height = 64;
      const ctx = sprite.getContext('2d');
      const color = rgb.map(v => Math.round(v * 255)).join(',');
      const glow = ctx.createRadialGradient(32,32,0,32,32,32);
      glow.addColorStop(0,`rgba(${color},.95)`);
      glow.addColorStop(.08,`rgba(${color},.72)`);
      glow.addColorStop(.22,`rgba(${color},.2)`);
      glow.addColorStop(.48,`rgba(${color},.035)`);
      glow.addColorStop(1,`rgba(${color},0)`);
      ctx.fillStyle=glow; ctx.fillRect(0,0,64,64); return sprite;
    });
    particles.forEach(p => { p.r=Math.hypot(p.x,p.y); p.sx=Math.sin(p.x*5); p.cx=Math.cos(p.x*5); p.sy=Math.sin(p.y*6); p.cy=Math.cos(p.y*6); p.fill = `rgba(${p.rgb.map(v=>Math.round(v*255)).join(',')},${p.brightness})`; p.sprite=glowSprites[palette.indexOf(p.rgb)]; });
    let renderer = createGalaxyRenderer(canvas, particles);
    let surface;
    let fallbackCanvas = canvas;
    if (renderer) {
      surface = renderer.resize();
      canvas.dataset.renderer = 'webgl';
    } else {
      // A separate canvas is necessary if WebGL claimed the original context.
      fallbackCanvas = document.createElement('canvas');
      fallbackCanvas.className = 'galaxy-fallback';
      fallbackCanvas.setAttribute('aria-hidden', 'true');
      canvas.parentElement.prepend(fallbackCanvas);
      surface = sizeCanvas(fallbackCanvas);
      if (!surface) return;
      canvas.dataset.renderer = 'canvas';
    }
    const fluidCanvas = document.createElement('canvas');
    fluidCanvas.className = 'galaxy-fluid'; fluidCanvas.setAttribute('aria-hidden','true');
    canvas.parentElement.prepend(fluidCanvas);
    let fluidSurface = sizeCanvas(fluidCanvas);
    const ribbons = [];
    // Contours share the stars' velocity field, so the liquid and dust move together.
    for (let arm=0; arm<2; arm++) {
      for (let band=0; band<16; band++) {
        const points=[];
        for (let j=0; j<160; j++) {
          const r=.025+j/159*.975;
          const a=arm*Math.PI+r*8.4+(band-7.5)*.013 + Math.sin(r*17+arm)*.05;
          const x=Math.cos(a)*r, y=Math.sin(a)*r;
          points.push({x,y,r,sx:Math.sin(x*5),cx:Math.cos(x*5),sy:Math.sin(y*6),cy:Math.cos(y*6)});
        }
        ribbons.push(points);
      }
    }
    const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
    const journey = document.querySelector('.galaxy-journey');
    const panels = [...document.querySelectorAll('[data-chapter]')];
    const chapterLinks = [...document.querySelectorAll('.journey-nav a')];
    const logo = document.querySelector('.galaxy-v');
    journey.classList.add('journey-ready');
    let paused = reducedMotion.matches, inView = true, contextLost = false, frame = 0, lastTime = 0;
    let angle = -.38, tilt = .5, flow = 0, dragging = false, pointerX = 0, pointerY = 0;
    let progress = 0, activeChapter = -1, scrollFrame = 0;
    let camera;
    function updateJourney() {
      const height = journey.getBoundingClientRect().height / 4.2;
      progress = clamp(-journey.getBoundingClientRect().top / height, 0, 3);
      const compact = surface.width <= 600;
      const stops = [
        {x:0,y:0,zoom:1,ax:.5,ay:compact ? .29 : .35,rotation:0,tilt:.5},
        {x:.42,y:-.2,zoom:2.6,ax:compact ? .5 : .72,ay:compact ? .65 : .5,rotation:.3,tilt:.68},
        {x:-.38,y:.24,zoom:1.8,ax:compact ? .5 : .7,ay:compact ? .62 : .5,rotation:-.35,tilt:.4},
        {x:.25,y:.42,zoom:3.1,ax:compact ? .5 : .72,ay:compact ? .65 : .5,rotation:.55,tilt:.7}
      ];
      const from = Math.min(2,Math.floor(progress)), mix = ease(progress - from);
      camera = Object.fromEntries(Object.keys(stops[0]).map(key => [key,stops[from][key]+(stops[from+1][key]-stops[from][key])*mix]));
      if (reducedMotion.matches) camera = stops[0];
      const chapter = Math.round(progress);
      if (chapter !== activeChapter) {
        panels.forEach((panel,i) => { panel.inert = i !== chapter; panel.setAttribute('aria-hidden',String(i !== chapter)); });
        chapterLinks.forEach((link,i) => { if (i === chapter) link.setAttribute('aria-current','step'); else link.removeAttribute('aria-current'); });
        activeChapter = chapter;
      }
      panels.forEach((panel,i) => {
        const distance = Math.abs(progress-i);
        const opacity = reducedMotion.matches ? Number(i === chapter) : 1-ease((distance-.15)/.35);
        panel.style.opacity = opacity;
        panel.style.visibility = opacity > 0 ? 'visible' : 'hidden';
        panel.style.transform = reducedMotion.matches ? 'none' : `translateY(${(i-progress)*22}px)`;
      });
      const geometry = cameraGeometry(surface,camera);
      logo.style.left = geometry.cx+'px'; logo.style.top = geometry.cy+'px';
      logo.style.opacity = 1-ease(progress/.65);
      logo.style.transform = `translate(-50%,-50%) scale(${reducedMotion.matches || paused ? 1 : camera.zoom})`;
      journey.dataset.chapter = String(chapter);
      canvas.dataset.chapter = String(chapter);
      canvas.dataset.zoom = camera.zoom.toFixed(2);
    }
    const toggle = document.querySelector('.galaxy-toggle');
    const reset = document.querySelector('.galaxy-reset');
    function updateToggle() {
      toggle.setAttribute('aria-pressed', String(paused));
      toggle.setAttribute('aria-label', paused ? 'Resume galaxy animation' : 'Pause galaxy animation');
      toggle.dataset.paused = String(paused);
    }
    function render(time = 0) {
      if (contextLost) return;
      const {radius:fr,cx:fcx,cy:fcy} = cameraGeometry(surface,camera);
      const fctx=fluidSurface.ctx;
      fctx.clearRect(0,0,surface.width,surface.height);
      fctx.globalCompositeOperation='lighter';
      const fca=Math.cos(angle+camera.rotation), fsa=Math.sin(angle+camera.rotation), fct=Math.cos(camera.tilt+tilt-.5), fst=Math.sin(camera.tilt+tilt-.5), fs=Math.sin(flow), fc=Math.cos(flow);
      ribbons.forEach((points,band) => {
        fctx.beginPath();
        points.forEach((p,j) => {
          const x=p.x+(p.sy*fc+p.cy*fs)*p.r*.065, y=p.y+(p.sx*fc-p.cx*fs)*p.r*.065;
          const rx=x*fca-y*fsa, ry=x*fsa+y*fca, perspective=1/(1+ry*fst*.22);
          const px=fcx+rx*fr*perspective, py=fcy+ry*fct*fr*perspective;
          if(j===0) fctx.moveTo(px,py); else fctx.lineTo(px,py);
        });
        fctx.strokeStyle = band%5===0 ? 'rgba(168,183,255,.12)' : 'rgba(112,145,241,.045)';
        fctx.lineWidth=Math.min(2,camera.zoom*.7); fctx.stroke();
      });
      fctx.globalCompositeOperation='source-over';
      if (renderer) { renderer.draw(surface, angle + camera.rotation, camera.tilt + tilt - .5, time, camera, flow); return; }
      const { ctx, width, height } = surface;
      const {cx,cy,radius} = cameraGeometry(surface,camera);
      ctx.clearRect(0,0,width,height); ctx.globalCompositeOperation = 'lighter';
      const halo = ctx.createRadialGradient(cx,cy,0,cx,cy,radius*.3);
      halo.addColorStop(0,'rgba(189,200,245,.09)');
      halo.addColorStop(.15,'rgba(214,222,241,.08)');
      halo.addColorStop(.5,'rgba(153,178,212,.015)');
      halo.addColorStop(1,'rgba(153,178,212,0)');
      ctx.fillStyle=halo; ctx.fillRect(cx-radius,cy-radius,radius*2,radius*2);
      const ca = Math.cos(angle+camera.rotation), sa = Math.sin(angle+camera.rotation), ct = Math.cos(camera.tilt+tilt-.5), st = Math.sin(camera.tilt+tilt-.5);
      const sf=Math.sin(flow), cf=Math.cos(flow);
      for (let i = 0; i < particles.length; i++) {
        const p = particles[i];
        const fx=p.x+(p.sy*cf+p.cy*sf)*p.r*.065, fy=p.y+(p.sx*cf-p.cx*sf)*p.r*.065;
        const x = fx * ca - fy * sa, y = fx * sa + fy * ca;
        const perspective = 1 / (1 + (y * st + p.z * ct) * .22);
        const px = p.kind ? cx + x * radius * perspective : p.x * width;
        const py = p.kind ? cy + (y * ct - p.z * st) * radius * perspective : p.y * height;
        if(px < -40 || px > width+40 || py < -40 || py > height+40) continue;
        const size = Math.min(3.8,Math.max(.35,p.size * radius / 450 * perspective));
        if(p.size > 1.15) {
          const glowSize=size*10;
          ctx.globalAlpha=p.brightness*.68;
          ctx.drawImage(p.sprite,px-glowSize/2,py-glowSize/2,glowSize,glowSize);
          ctx.globalAlpha=1;
        }
        ctx.fillStyle=p.fill;
        ctx.fillRect(px-size*.35,py-size*.35,size*.7,size*.7);
      }
      ctx.globalCompositeOperation = 'source-over';
    }
    function animate(time) {
      frame = 0;
      if (paused || !inView || contextLost || document.hidden) return;
      const elapsed = lastTime ? Math.min(time - lastTime, 64) : 0;
      if (elapsed < (renderer ? 15 : 32) && elapsed > 0) { frame = requestAnimationFrame(animate); return; }
      if (!dragging) angle += elapsed * .000006;
      flow += elapsed * .00012;
      lastTime = time; render(time);
      frame = requestAnimationFrame(animate);
    }
    function sync() {
      cancelAnimationFrame(frame); frame = 0; lastTime = 0;
      updateJourney(); render();
      if (!paused && inView && !contextLost && !document.hidden) frame = requestAnimationFrame(animate);
    }
    toggle.addEventListener('click', () => { paused = !paused; updateToggle(); sync(); });
    reset.addEventListener('click', () => { angle = -.38; tilt = .5; flow = 0; sync(); });
    canvas.addEventListener('pointerdown', e => { dragging = true; pointerX = e.clientX; pointerY = e.clientY; canvas.setPointerCapture(e.pointerId); });
    canvas.addEventListener('pointermove', e => {
      if (!dragging) return;
      angle += (e.clientX - pointerX) * .006;
      tilt = Math.max(-.9, Math.min(.9, tilt + (e.clientY - pointerY) * .004));
      pointerX = e.clientX; pointerY = e.clientY;
      render();
    });
    const release = () => { dragging = false; };
    canvas.addEventListener('pointerup', release); canvas.addEventListener('pointercancel', release); canvas.addEventListener('lostpointercapture', release);
    canvas.addEventListener('keydown', e => {
      if (!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(e.key)) return;
      e.preventDefault();
      if (e.key === 'ArrowLeft') angle -= .12;
      if (e.key === 'ArrowRight') angle += .12;
      if (e.key === 'ArrowUp') tilt = Math.max(-.9, tilt - .1);
      if (e.key === 'ArrowDown') tilt = Math.min(.9, tilt + .1);
      if (e.key === 'Home') { angle = -.38; tilt = .5; flow = 0; }
      render();
    });
    reducedMotion.addEventListener('change', () => { paused = reducedMotion.matches; updateToggle(); sync(); });
    document.addEventListener('visibilitychange', sync);
    if ('IntersectionObserver' in window) new IntersectionObserver(entries => { inView = entries[0].isIntersecting; sync(); }).observe(canvas);
    resizeHero = () => { fluidSurface = sizeCanvas(fluidCanvas) || fluidSurface; surface = renderer ? renderer.resize() : sizeCanvas(fallbackCanvas) || surface; sync(); };
    canvas.addEventListener('webglcontextlost', e => { e.preventDefault(); contextLost = true; sync(); });
    canvas.addEventListener('webglcontextrestored', () => { const restored = createGalaxyRenderer(canvas, particles); if (restored) { renderer = restored; contextLost = false; surface = renderer.resize(); sync(); } });
    window.addEventListener('scroll', () => {
      if (scrollFrame) return;
      scrollFrame = requestAnimationFrame(() => { scrollFrame = 0; updateJourney(); render(); });
    }, {passive:true});
    updateToggle(); sync();
  }
  let resizeFrame = 0;
  window.addEventListener('resize', () => {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => { drawBackground(); orbitCanvases.forEach(drawOrbit); resizeHero(); });
  });
})();
