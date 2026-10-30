/* ============================================================
   Boost — interactions
   ============================================================ */
(() => {
  "use strict";

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------------------------------------------------- menu bar */
  const bar = $(".menubar");
  const closeSec = $(".close");
  const onScroll = () => {
    bar.classList.toggle("is-scrolled", window.scrollY > 18);
    if (closeSec) {
      const r = closeSec.getBoundingClientRect();
      bar.classList.toggle("is-mint", r.top <= 54 && r.bottom > 54);
    }
  };
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });
  window.addEventListener("resize", onScroll, { passive: true });

  /* ---------------------------------------------------- reveal */
  const reveals = $$(".reveal");
  if ("IntersectionObserver" in window && !reduced) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            io.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -6% 0px" }
    );
    reveals.forEach((el) => io.observe(el));
  } else {
    reveals.forEach((el) => el.classList.add("in"));
  }

  /* ---------------------------------------------------- copy */
  async function writeClipboard(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (err) {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      let ok = false;
      try { ok = document.execCommand("copy"); } catch (e) { ok = false; }
      ta.remove();
      return ok;
    }
  }

  $$("[data-copy]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const ok = await writeClipboard(btn.dataset.copy);
      if (!ok) return;
      const label = btn.querySelector(".copy-mini span");
      const icon = btn.querySelector(".copy .ico, .copy-mini .ico");
      const previous = icon ? icon.innerHTML : null;
      if (label) label.textContent = "Copied";
      if (icon) icon.innerHTML = '<use href="#i-check"/>';
      btn.classList.add("is-copied");
      window.setTimeout(() => {
        if (label) label.textContent = "Copy";
        if (icon && previous !== null) icon.innerHTML = previous;
        btn.classList.remove("is-copied");
      }, 1600);
    });
  });

  /* ---------------------------------------------------- hero popover */
  const pop = $("#pop");
  const usedEl = $("#usedGb");
  const pctEl = $("#gaugePct");
  const gauge = $("#gaugeVal");
  const gaugeSvg = $("#gauge");
  const statusEl = $("#popStatus");
  const cachedEl = $("#cachedGb");
  const resultEl = $("#popResult");
  const freeBtn = $("#freeBtn");

  const states = [
    { used: 11.11, pct: 69, cached: "3.75 GB", status: "Getting busy" },
    { used: 10.37, pct: 65, cached: "3.01 GB", status: "Getting busy" },
    { used: 10.36, pct: 65, cached: "3.00 GB", status: "Getting busy" },
    { used: 10.36, pct: 65, cached: "3.00 GB", status: "Getting busy" }
  ];
  const results = [
    "No app closing. No admin password.",
    "<b>742 MB</b> returned · swap stayed flat · 0 apps closed.",
    "<b>9 MB</b> returned. Nothing else was idle.",
    "<b>0 MB.</b> Nothing left to give. That is the honest answer."
  ];

  let stateIndex = 0;
  let busy = false;
  let tweenGen = 0;

  function setGauge(pct) {
    gauge.style.strokeDashoffset = (100 - pct).toFixed(2);
    gaugeSvg.setAttribute("aria-label", `Memory pressure: ${Math.round(pct)} percent`);
  }

  if (gauge) {
    if (reduced) {
      setGauge(69);
    } else {
      gauge.style.transition = "none";
      gauge.style.strokeDashoffset = 100;
      requestAnimationFrame(() => {
        gauge.style.transition = "";
        window.setTimeout(() => setGauge(69), 420);
      });
    }
  }

  function tween(from, to, duration, done) {
    if (reduced) { done(to); return; }
    const gen = tweenGen;
    const start = performance.now();
    function frame(now) {
      if (gen !== tweenGen) return;
      const t = Math.min(1, (now - start) / duration);
      const eased = 1 - Math.pow(1 - t, 3);
      done(from + (to - from) * eased);
      if (t < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  }

  function resetDemo() {
    tweenGen += 1;
    stateIndex = 0;
    busy = false;
    const s = states[0];
    usedEl.textContent = s.used.toFixed(2);
    pctEl.textContent = "69";
    cachedEl.textContent = s.cached;
    statusEl.querySelector("span").textContent = s.status;
    setGauge(s.pct);
    resultEl.classList.remove("is-live");
    resultEl.textContent = results[0];
    const label = freeBtn.querySelector("span");
    label.textContent = "Free Memory";
    freeBtn.disabled = false;
  }

  if (freeBtn) {
    freeBtn.addEventListener("click", () => {
      if (busy || stateIndex >= 3) return;
      busy = true;
      freeBtn.disabled = true;
      const prev = states[stateIndex];
      const nextIndex = Math.min(stateIndex + 1, 3);
      const next = states[nextIndex];
      const label = freeBtn.querySelector("span");
      label.textContent = "Asking macOS…";
      resultEl.classList.add("is-live");
      resultEl.textContent = "memory_pressure: checking swap…";

      window.setTimeout(() => {
        tween(prev.used, next.used, 820, (v) => { usedEl.textContent = v.toFixed(2); });
        tween(prev.pct, next.pct, 820, (v) => { pctEl.textContent = String(Math.round(v)); });
        setGauge(next.pct);

        window.setTimeout(() => {
          cachedEl.textContent = next.cached;
          statusEl.querySelector("span").textContent = next.status;
          resultEl.innerHTML = results[nextIndex] + (nextIndex >= 1 ? ' <button class="reset" type="button">reset</button>' : "");
          stateIndex = nextIndex;
          busy = false;
          label.textContent = nextIndex >= 3 ? "Nothing to free" : "Free Memory";
          freeBtn.disabled = nextIndex >= 3;
          const reset = resultEl.querySelector(".reset");
          if (reset) reset.addEventListener("click", resetDemo);
        }, 260);
      }, 700);
    });
  }

  /* ---------------------------------------------------- memory anatomy */
  const anatomyText = {
    wired: "<b>Wired.</b> Kernel, drivers and everything that cannot be paged out. Shrinking it is not an option.",
    apps: "<b>Apps.</b> The pages your open apps are actively using. This is the memory that actually belongs to your work.",
    compressed: "<b>Compressed.</b> macOS squeezed these pages in RAM instead of writing them to disk. Reading compressed memory is much faster than reading an SSD.",
    cached: "<b>Cached memory is available memory.</b> Files kept in RAM because nothing else needed it. The instant an app asks, macOS hands it over. A big cache is a Mac using spare memory well, not a Mac that is full.",
    free: "<b>Free.</b> Actually unused. macOS tries to keep this small, because RAM doing nothing is RAM wasted."
  };
  const anatomyDetail = $("#anatomyDetail");
  const legendButtons = $$(".legend button");
  legendButtons.forEach((btn) => {
    btn.addEventListener("click", () => {
      legendButtons.forEach((b) => b.setAttribute("aria-pressed", String(b === btn)));
      if (anatomyDetail && anatomyText[btn.dataset.key]) anatomyDetail.innerHTML = anatomyText[btn.dataset.key];
    });
  });

  /* ---------------------------------------------------- screenshot tabs */
  const shotTabs = $$(".shots-tabs button");
  const shots = $$(".shot");
  const markers = $("#shotMarkers");
  const shotCap = $("#shotCap");
  const shotTitle = $(".shots-title");
  const shotCaps = {
    memory: "Every app and its helpers, grouped into one row with a real total.",
    disk: "Allowlist only. A folder is listed when its manifest proves what it is.",
    uninstall: "Leftovers with sizes before anything moves. Exact matches only. Undo.",
    models: "Ollama, Hugging Face and LM Studio models. Sizes are what removing each one frees."
  };
  shotTabs.forEach((tab, index) => {
    tab.addEventListener("click", () => {
      shotTabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
      shots.forEach((img, i) => {
        img.classList.toggle("on", i === index);
        img.setAttribute("aria-hidden", String(i !== index));
      });
      if (markers) markers.hidden = tab.dataset.shot !== "memory";
      const stage = shots[index] && shots[index].parentElement;
      if (stage && shots[index].width && shots[index].height) {
        stage.style.aspectRatio = shots[index].getAttribute("width") + " / " + shots[index].getAttribute("height");
      }
      if (shotCap) shotCap.textContent = shotCaps[tab.dataset.shot];
      if (shotTitle) shotTitle.textContent = "Boost \u00b7 " + tab.textContent.trim();
    });
  });

  /* ---------------------------------------------------- pause demo */
  const freeze = $("#freeze");
  const pauseBtn = $("#pauseBtn");
  const freezeMeta = $("#freezeMeta");
  const freezeNote = $("#freezeNote");
  let paused = false;

  if (pauseBtn && freeze) {
    pauseBtn.addEventListener("click", () => {
      paused = !paused;
      freeze.classList.toggle("is-paused", paused);
      pauseBtn.setAttribute("aria-pressed", String(paused));
      pauseBtn.textContent = paused ? "Resume" : "Pause";
      freezeMeta.textContent = paused ? "4 windows · 1.2 GB · paused" : "4 windows · 1.2 GB · 6.4% CPU";
      freezeNote.textContent = paused
        ? "Frozen with SIGSTOP. No CPU, no state lost. Resume puts it back exactly here."
        : "Pause freezes the app and its helpers. Resume puts everything back where it was.";
    });
  }

  /* ---------------------------------------------------- disk allowlist */
  const diskRows = $$(".disk-row");
  const diskSelected = $("#diskSelected");
  const diskTotalLabel = $("#diskTotalLabel");

  function formatSize(mb) {
    if (mb <= 0) return "0 B";
    if (mb >= 1024) return (mb / 1024).toFixed(2) + " GB";
    return Math.round(mb) + " MB";
  }

  if (diskRows.length && diskSelected) {
    const total = diskRows.reduce((sum, row) => sum + Number(row.querySelector("input").dataset.size), 0);
    if (diskTotalLabel) diskTotalLabel.textContent = "selected of " + formatSize(total);

    const updateDisk = () => {
      let sum = 0;
      diskRows.forEach((row) => {
        const input = row.querySelector("input");
        row.classList.toggle("checked", input.checked);
        if (input.checked) sum += Number(input.dataset.size);
      });
      diskSelected.textContent = formatSize(sum);
    };

    diskRows.forEach((row) => row.querySelector("input").addEventListener("change", updateDisk));
    updateDisk();
  }

  /* ---------------------------------------------------- history chart */
  const chart = {
    "2h": {
      values: [66, 68, 71, 74, 72, 69, 67, 65, 64, 62, 60, 59, 61, 63, 66, 68, 71, 74, 76, 73, 70, 68, 67, 65],
      labels: ["2h ago", "90m", "60m", "30m", "now"],
      swap: 0,
      range: "2 hours",
      annot: null,
      time: (i) => `${(23 - i) * 5} min ago`
    },
    "24h": {
      values: [88, 84, 79, 72, 66, 61, 58, 55, 53, 51, 54, 58, 63, 69, 74, 71, 68, 73, 79, 84, 81, 76, 70, 66],
      labels: ["00", "04", "08", "12", "16", "20", "now"],
      swap: 2,
      range: "24 hours",
      annot: null,
      time: (i) => `${String(i).padStart(2, "0")}:00`
    },
    "7d": {
      values: [42, 48, 45, 52, 61, 55, 58, 92, 53, 58, 64, 59, 62, 68, 74, 71, 71, 78, 73, 69, 66, 72, 63, 58, 61, 57, 54, 52],
      labels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
      swap: 4,
      range: "7 days",
      annot: { index: 7, html: "Tue 18:00 · <b>92%</b>" },
      time: (i) => {
        const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
        return `${days[Math.floor(i / 4)]} ${String((i % 4) * 6).padStart(2, "0")}:00`;
      }
    }
  };

  const X0 = 40;
  const X1 = 1000;
  const Y0 = 16;
  const Y1 = 290;
  const chartLine = $("#chartLine");
  const chartArea = $("#chartArea");
  const chartDot = $("#chartDot");
  const chartTip = $("#chartTip");
  const chartAnnot = $("#chartAnnot");
  const chartPlot = $("#chartPlot");
  const chartX = $("#chartX");
  const chartRange = $("#chartRange");
  const statPeak = $("#statPeak");
  const statAvg = $("#statAvg");
  const statSwap = $("#statSwap");
  const chartDesc = $("#chartDesc");
  const rangeButtons = $$(".range button");
  let currentChart = null;

  function buildGeometry(values) {
    const n = values.length;
    const pts = values.map((v, i) => [
      X0 + (i / (n - 1)) * (X1 - X0),
      Y1 - (v / 100) * (Y1 - Y0)
    ]);
    let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
    for (let i = 0; i < n - 1; i += 1) {
      const p0 = pts[i - 1] || pts[i];
      const p1 = pts[i];
      const p2 = pts[i + 1];
      const p3 = pts[i + 2] || p2;
      const c1x = p1[0] + (p2[0] - p0[0]) / 6;
      const c1y = p1[1] + (p2[1] - p0[1]) / 6;
      const c2x = p2[0] - (p3[0] - p1[0]) / 6;
      const c2y = p2[1] - (p3[1] - p1[1]) / 6;
      d += ` C${c1x.toFixed(1)},${c1y.toFixed(1)} ${c2x.toFixed(1)},${c2y.toFixed(1)} ${p2[0].toFixed(1)},${p2[1].toFixed(1)}`;
    }
    return { d, area: `${d} L${X1},${Y1} L${X0},${Y1} Z`, pts };
  }

  function drawChart(key, animate) {
    const mode = chart[key];
    if (!mode || !chartLine) return;
    const geometry = buildGeometry(mode.values);
    currentChart = { mode, ...geometry };

    chartLine.setAttribute("d", geometry.d);
    chartArea.setAttribute("d", geometry.area);
    chartArea.classList.remove("in");

    const peak = Math.max(...mode.values);
    const avg = Math.round(mode.values.reduce((a, b) => a + b, 0) / mode.values.length);
    if (statPeak) statPeak.textContent = peak + "%";
    if (statAvg) statAvg.textContent = avg + "%";
    if (statSwap) {
      statSwap.textContent = String(mode.swap);
      statSwap.parentElement.classList.toggle("warn", mode.swap > 0);
    }
    if (chartRange) chartRange.textContent = mode.range;
    if (chartX) chartX.innerHTML = mode.labels.map((label) => `<span>${label}</span>`).join("");
    if (chartDesc) chartDesc.textContent = `Pressure peaks at ${peak} percent, averages ${avg} percent, and triggers ${mode.swap} swap event${mode.swap === 1 ? "" : "s"}.`;

    if (chartAnnot) {
      if (mode.annot) {
        const [px, py] = geometry.pts[mode.annot.index];
        chartAnnot.hidden = false;
        chartAnnot.style.left = (px / 1000) * 100 + "%";
        chartAnnot.style.top = (py / 320) * 100 + "%";
        chartAnnot.innerHTML = mode.annot.html;
      } else {
        chartAnnot.hidden = true;
      }
    }

    if (chartDot) chartDot.classList.remove("on");
    if (chartTip) chartTip.classList.remove("on");

    if (animate && !reduced) {
      const length = chartLine.getTotalLength();
      chartLine.style.transition = "none";
      chartLine.style.strokeDasharray = String(length);
      chartLine.style.strokeDashoffset = String(length);
      requestAnimationFrame(() => {
        chartLine.style.transition = "stroke-dashoffset 1.15s cubic-bezier(.16,1,.3,1)";
        chartLine.style.strokeDashoffset = "0";
      });
      requestAnimationFrame(() => chartArea.classList.add("in"));
    } else {
      chartLine.style.transition = "none";
      chartLine.style.strokeDasharray = "";
      chartLine.style.strokeDashoffset = "0";
      chartArea.classList.add("in");
    }
  }

  if (chartLine) {
    drawChart("7d", false);

    let chartSeen = false;
    if ("IntersectionObserver" in window && !reduced) {
      const chartIO = new IntersectionObserver(
        (entries) => {
          entries.forEach((entry) => {
            if (entry.isIntersecting && !chartSeen) {
              chartSeen = true;
              drawChart("7d", true);
              chartIO.disconnect();
            }
          });
        },
        { threshold: 0.25 }
      );
      chartIO.observe($(".chart-panel"));
    }

    rangeButtons.forEach((btn) => {
      btn.addEventListener("click", () => {
        rangeButtons.forEach((b) => b.setAttribute("aria-selected", String(b === btn)));
        drawChart(btn.dataset.range, true);
      });
    });

    if (chartPlot) {
      chartPlot.addEventListener("pointermove", (event) => {
        if (!currentChart) return;
        const rect = chartPlot.getBoundingClientRect();
        const x = ((event.clientX - rect.left) / rect.width) * 1000;
        const n = currentChart.pts.length;
        let index = Math.round((x - X0) / ((X1 - X0) / (n - 1)));
        index = Math.max(0, Math.min(n - 1, index));
        const point = currentChart.pts[index];
        if (chartDot) {
          chartDot.setAttribute("cx", point[0]);
          chartDot.setAttribute("cy", point[1]);
          chartDot.classList.add("on");
        }
        if (chartTip) {
          chartTip.style.left = Math.min(92, Math.max(8, (point[0] / 1000) * 100)) + "%";
          chartTip.style.top = (point[1] / 320) * 100 + "%";
          chartTip.innerHTML = `<b>${currentChart.mode.values[index]}%</b> · ${currentChart.mode.time(index)}`;
          chartTip.classList.add("on");
        }
        if (chartAnnot) chartAnnot.classList.add("hide");
      });

      chartPlot.addEventListener("pointerleave", () => {
        if (chartDot) chartDot.classList.remove("on");
        if (chartTip) chartTip.classList.remove("on");
        if (chartAnnot) chartAnnot.classList.remove("hide");
      });
    }
  }

  /* ---------------------------------------------------- install tabs */
  const installCode = $("#installCode");
  const installTabs = $$(".installer-bar [data-install]");
  const installCopy = $(".installer-bar [data-copy]");
  const installs = {
    brew: {
      code: '<span class="p">$</span> brew install --cask kernel-hunter/boost/boost',
      copy: "brew install --cask kernel-hunter/boost/boost"
    },
    source: {
      code: '<span class="p">$</span> git clone https://github.com/Kernel-Hunter/boost.git\n<span class="p">$</span> cd boost &amp;&amp; ./Scripts/build.sh',
      copy: "git clone https://github.com/Kernel-Hunter/boost.git\ncd boost && ./Scripts/build.sh"
    }
  };

  installTabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      const entry = installs[tab.dataset.install];
      if (!entry || !installCode) return;
      installTabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
      installCode.innerHTML = entry.code;
      if (installCopy) {
        installCopy.dataset.copy = entry.copy;
        const label = installCopy.querySelector("span");
        if (label) label.textContent = "Copy";
        installCopy.classList.remove("is-copied");
      }
    });
  });
})();
