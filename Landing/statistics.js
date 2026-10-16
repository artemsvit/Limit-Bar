(() => {
  const demo = document.querySelector("[data-statistics-demo]");
  if (!demo) return;

  const providers = {
    codex: { name: "Codex", color: "#8f86ff", session: [96, 90, 78, 78, 65, 52, 45, 33], weekly: [84, 82, 80, 77, 75, 72, 70, 68] },
    claude: { name: "Claude", color: "#e59b7d", session: [82, 65, 47, 32, 8, 100, 98, 91], weekly: [45, 44, 40, 30, 14, 100, 100, 98] },
    antigravity: { name: "Antigravity", color: "#6ed7ac", session: [100, 92, 92, 84, 80, 76, 70, 64], weekly: [90, 88, 85, 84, 80, 78, 76, 72] }
  };
  const motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let provider = "codex";
  let windowKind = "session";
  let selected = 7;
  let visible = false;
  let animationFrame;
  const find = (name) => demo.querySelector(`[data-statistics-${name}]`);
  const time = (index) => `${9 + Math.floor(index / 4)}:${String((index % 4) * 15).padStart(2, "0")} AM`;
  const position = (index, value) => [10 + index * (680 / 7), 190 - value * 1.8];

  function animate() {
    cancelAnimationFrame(animationFrame);
    demo.classList.remove("is-drawing");
    if (!visible || motion.matches) return;
    animationFrame = requestAnimationFrame(() => {
      animationFrame = requestAnimationFrame(() => demo.classList.add("is-drawing"));
    });
  }

  function inspect(index) {
    selected = index;
    const data = providers[provider];
    const [x, y] = position(index, data[windowKind][index]);
    find("guide").setAttribute("x1", x);
    find("guide").setAttribute("x2", x);
    find("point").setAttribute("cx", x);
    find("point").setAttribute("cy", y);
    find("reading-label").textContent = `${index === 7 ? "Latest" : "Selected"} reading · ${time(index)}`;
    find("selected").textContent = `${data.session[index]}% session · ${data.weekly[index]}% weekly`;
    demo.querySelectorAll("[data-statistics-reading]").forEach((button) => {
      button.setAttribute("aria-pressed", String(Number(button.dataset.statisticsReading) === index));
    });
  }

  function render() {
    const data = providers[provider];
    const values = data[windowKind];
    const points = values.map((value, index) => position(index, value));
    const path = points.map(([x, y], index) => `${index ? "L" : "M"}${x} ${y}`).join(" ");
    demo.style.setProperty("--statistics-accent", data.color);
    find("line").setAttribute("d", path);
    find("area").setAttribute("d", `${path} L690 190 L10 190Z`);
    find("latest").textContent = `${values[7]}%`;
    find("lowest").textContent = `${Math.min(...values)}%`;
    const drop = values.reduce((sum, value, index) => sum + (index ? Math.max(0, values[index - 1] - value) : 0), 0);
    find("drop").replaceChildren(document.createTextNode(`${drop} `), Object.assign(document.createElement("em"), { textContent: "pp" }));
    find("chart-title").textContent = `${windowKind === "session" ? "Session" : "Weekly"} remaining`;
    demo.querySelectorAll("[data-statistics-provider]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.statisticsProvider === provider));
    });
    demo.querySelectorAll("[data-statistics-provider-value]").forEach((label) => {
      label.textContent = `${providers[label.dataset.statisticsProviderValue][windowKind][7]}% · ${windowKind}`;
    });
    demo.querySelectorAll("[data-statistics-window]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.statisticsWindow === windowKind));
    });
    for (const index of [7, 6, 5]) {
      demo.querySelector(`[data-statistics-row-session="${index}"]`).textContent = `${data.session[index]}%`;
      demo.querySelector(`[data-statistics-row-weekly="${index}"]`).textContent = `${data.weekly[index]}%`;
      const difference = values[index] - values[index - 1];
      const change = demo.querySelector(`[data-statistics-row-change="${index}"]`);
      change.textContent = difference ? `${difference > 0 ? "+" : "−"}${Math.abs(difference)} pp` : "No change";
      change.classList.toggle("is-increase", difference > 0);
    }
    inspect(selected);
    animate();
  }

  demo.querySelectorAll("[data-statistics-provider]").forEach((button) => {
    button.addEventListener("click", () => { provider = button.dataset.statisticsProvider; selected = 7; render(); });
  });
  demo.querySelectorAll("[data-statistics-window]").forEach((button) => {
    button.addEventListener("click", () => { windowKind = button.dataset.statisticsWindow; selected = 7; render(); });
  });
  demo.querySelectorAll("[data-statistics-reading]").forEach((button) => {
    button.addEventListener("click", () => inspect(Number(button.dataset.statisticsReading)));
  });
  find("export").addEventListener("click", () => {
    const data = providers[provider];
    const rows = ["provider,recorded_at,session_remaining_percent,weekly_remaining_percent"];
    for (let index = 0; index < 8; index += 1) {
      const date = new Date(Date.UTC(2026, 9, 16, 9, index * 15));
      rows.push(`${data.name},${date.toISOString()},${data.session[index]},${data.weekly[index]}`);
    }
    const url = URL.createObjectURL(new Blob([rows.join("\r\n") + "\r\n"], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `limit-bar-${provider}-sample-history.csv`;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });

  demo.classList.add("demo-ready");
  render();
  const reveal = () => { visible = true; demo.classList.add("is-visible"); animate(); };
  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) { reveal(); observer.disconnect(); }
    }, { threshold: 0.15 });
    observer.observe(demo);
  } else reveal();
  motion.addEventListener("change", () => {
    if (motion.matches) { cancelAnimationFrame(animationFrame); demo.classList.remove("is-drawing"); }
  });
})();
