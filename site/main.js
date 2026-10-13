(function () {
  var root = document.documentElement;

  var titles = {
    en: "MailSift — find any email by describing it",
    zh: "MailSift — 用一句話找到任何一封信"
  };
  function setLang(lang, remember) {
    root.setAttribute("data-lang", lang);
    root.lang = lang === "zh" ? "zh-Hant-TW" : "en";
    document.title = titles[lang];
    document.querySelectorAll("[data-set-lang]").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.getAttribute("data-set-lang") === lang));
    });
    if (remember) { try { localStorage.setItem("mailsift-lang", lang); } catch (e) {} }
  }
  setLang(root.getAttribute("data-lang") || "en", false);
  document.querySelectorAll("[data-set-lang]").forEach(function (b) {
    b.addEventListener("click", function () { setLang(b.getAttribute("data-set-lang"), true); });
  });

  // The window: type the query, then show the results
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  var win = document.querySelector(".window");
  var q = win.querySelector("[data-query]");
  var chars = Array.from(q.getAttribute("data-query"));
  var rows = win.querySelectorAll(".rows li");
  var n = 0;
  win.classList.add("typing", "waiting");
  q.textContent = "";
  (function step() {
    if (n < chars.length) { q.textContent += chars[n++]; setTimeout(step, 140); return; }
    setTimeout(function () {
      rows.forEach(function (r, i) { r.style.transitionDelay = (i * 90) + "ms"; });
      win.classList.remove("waiting");
      setTimeout(function () { win.classList.remove("typing"); }, 1600);
    }, 350);
  })();
})();
