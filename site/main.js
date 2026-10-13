(function () {
  var root = document.documentElement;
  var search = document.querySelector(".search");

  // Language switch
  var titles = {
    en: "MailSift — search Apple Mail by meaning",
    zh: "MailSift — 用意思搜尋 Apple Mail"
  };
  function setLang(lang, remember) {
    root.setAttribute("data-lang", lang);
    root.lang = lang === "zh" ? "zh-Hant-TW" : "en";
    document.title = titles[lang];
    document.querySelectorAll("[data-set-lang]").forEach(function (b) {
      b.setAttribute("aria-pressed", String(b.getAttribute("data-set-lang") === lang));
    });
    if (remember) { try { localStorage.setItem("mailsift-lang", lang); } catch (e) {} }
    typeQuery();
  }

  // Hero: type the query, then show the results. The query differs per language, so it restarts on switch.
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var timer = null;
  function typeQuery() {
    if (!search || reduced) return;
    clearTimeout(timer);
    var el = search.querySelector(".query ." + (root.getAttribute("data-lang") === "zh" ? "zh" : "en"));
    var text = el.getAttribute("data-query");
    var chars = Array.from(text);
    var hits = Array.prototype.slice.call(search.querySelectorAll(".hit"));
    var n = 0;
    search.classList.add("typing", "waiting");
    hits.forEach(function (h) { h.style.transitionDelay = ""; });
    el.textContent = "";
    (function step() {
      if (n < chars.length) {
        el.textContent += chars[n++];
        timer = setTimeout(step, chars.length > 12 ? 45 : 110);
        return;
      }
      timer = setTimeout(function () {
        hits.forEach(function (h, i) { h.style.transitionDelay = (i * 90) + "ms"; });
        search.classList.remove("waiting");
        timer = setTimeout(function () { search.classList.remove("typing"); }, 1800);
      }, 350);
    })();
  }

  setLang(root.getAttribute("data-lang") || "en", false);
  document.querySelectorAll("[data-set-lang]").forEach(function (b) {
    b.addEventListener("click", function () { setLang(b.getAttribute("data-set-lang"), true); });
  });

  // Hairline under the bar once the page scrolls
  var bar = document.querySelector(".bar");
  function onScroll() { bar.classList.toggle("scrolled", window.scrollY > 8); }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  // Hook for real screenshots later: an <img data-optional> inside a .shot figure that fails to load
  // removes itself, so the mockup next to it (or the copy alone) is what remains.
  document.querySelectorAll("img[data-optional]").forEach(function (img) {
    function drop() { img.closest(".shot").remove(); }
    if (img.complete && img.naturalWidth === 0) drop();
    else img.addEventListener("error", drop);
  });
})();
