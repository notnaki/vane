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
      varying vec3 v_color;
      varying float v_brightness;
      void main() {
        float ca = cos(u_angle), sa = sin(u_angle);
        float ct = cos(u_tilt), st = sin(u_tilt);
        vec3 p = a_position;
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
    const uniforms = Object.fromEntries(['resolution','center','radius','angle','tilt','dpr','time','bloom'].map(name => [name,gl.getUniformLocation(program,'u_'+name)]));
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
      draw({width,height,dpr}, angle, tilt, time) {
        const compact = width <= 900;
        gl.clearColor(0,0,0,0); gl.clear(gl.COLOR_BUFFER_BIT);
        gl.uniform2f(uniforms.resolution,width,height);
        gl.uniform2f(uniforms.center,width * (compact ? .53 : .76),height * (compact ? .28 : .48));
        gl.uniform1f(uniforms.radius,compact ? Math.min(width * .44,height * .24) : Math.min(width * .25,height * .4));
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
    const palette = [[.77,.86,1],[.94,.96,1],[1,.78,.53]];
    const count = window.innerWidth < 600 ? 9500 : 18000;
    for (let i = 0; i < count; i++) {
      const core = i < count * .14;
      const diffuse = !core && rng() < .28;
      const r = core ? Math.abs(gaussian()) * .125 : .055 + Math.pow(rng(), .82) * .945;
      const arm = i % 2;
      const spread = .105 + r * .2;
      const a = core || diffuse ? rng() * Math.PI * 2 : arm * Math.PI + r * 9.2 + gaussian() * spread;
      const clump = 1 + .035 * Math.sin(r * 48 + arm);
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
    particles.forEach(p => { p.fill = `rgba(${p.rgb.map(v=>Math.round(v*255)).join(',')},${p.brightness})`; p.sprite=glowSprites[palette.indexOf(p.rgb)]; });
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
    const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
    let paused = reducedMotion.matches, inView = true, contextLost = false, frame = 0, lastTime = 0;
    let angle = -.38, tilt = .75, dragging = false, pointerX = 0, pointerY = 0;
    const toggle = document.querySelector('.galaxy-toggle');
    const reset = document.querySelector('.galaxy-reset');
    function updateToggle() {
      toggle.setAttribute('aria-pressed', String(paused));
      toggle.setAttribute('aria-label', paused ? 'Resume galaxy animation' : 'Pause galaxy animation');
      toggle.dataset.paused = String(paused);
    }
    function render(time = 0) {
      if (contextLost) return;
      if (renderer) { renderer.draw(surface, angle, tilt, time); return; }
      const { ctx, width, height } = surface;
      const compact = width <= 900;
      const cx = width * (compact ? .53 : .76), cy = height * (compact ? .28 : .48);
      const radius = compact ? Math.min(width * .44,height * .24) : Math.min(width * .25,height * .4);
      ctx.clearRect(0,0,width,height); ctx.globalCompositeOperation = 'lighter';
      const halo = ctx.createRadialGradient(cx,cy,0,cx,cy,radius*.3);
      halo.addColorStop(0,'rgba(231,233,245,.23)');
      halo.addColorStop(.15,'rgba(214,222,241,.08)');
      halo.addColorStop(.5,'rgba(153,178,212,.015)');
      halo.addColorStop(1,'rgba(153,178,212,0)');
      ctx.fillStyle=halo; ctx.fillRect(cx-radius,cy-radius,radius*2,radius*2);
      const ca = Math.cos(angle), sa = Math.sin(angle), ct = Math.cos(tilt), st = Math.sin(tilt);
      for (let i = 0; i < particles.length; i++) {
        const p = particles[i];
        const x = p.x * ca - p.y * sa, y = p.x * sa + p.y * ca;
        const perspective = 1 / (1 + (y * st + p.z * ct) * .22);
        const px = p.kind ? cx + x * radius * perspective : p.x * width;
        const py = p.kind ? cy + (y * ct - p.z * st) * radius * perspective : p.y * height;
        const size = Math.max(.35,p.size * radius / 300 * perspective);
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
      if (!dragging) angle += elapsed * .000015;
      lastTime = time; render(time);
      frame = requestAnimationFrame(animate);
    }
    function sync() {
      cancelAnimationFrame(frame); frame = 0; lastTime = 0;
      render();
      if (!paused && inView && !contextLost && !document.hidden) frame = requestAnimationFrame(animate);
    }
    toggle.addEventListener('click', () => { paused = !paused; updateToggle(); sync(); });
    reset.addEventListener('click', () => { angle = -.38; tilt = .75; sync(); });
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
      if (e.key === 'Home') { angle = -.38; tilt = .75; }
      render();
    });
    reducedMotion.addEventListener('change', () => { paused = reducedMotion.matches; updateToggle(); sync(); });
    document.addEventListener('visibilitychange', sync);
    if ('IntersectionObserver' in window) new IntersectionObserver(entries => { inView = entries[0].isIntersecting; sync(); }).observe(canvas);
    resizeHero = () => { surface = renderer ? renderer.resize() : sizeCanvas(fallbackCanvas) || surface; sync(); };
    canvas.addEventListener('webglcontextlost', e => { e.preventDefault(); contextLost = true; sync(); });
    canvas.addEventListener('webglcontextrestored', () => { const restored = createGalaxyRenderer(canvas, particles); if (restored) { renderer = restored; contextLost = false; surface = renderer.resize(); sync(); } });
    updateToggle(); sync();
  }
  let resizeFrame = 0;
  window.addEventListener('resize', () => {
    cancelAnimationFrame(resizeFrame);
    resizeFrame = requestAnimationFrame(() => { drawBackground(); orbitCanvases.forEach(drawOrbit); resizeHero(); });
  });
})();
