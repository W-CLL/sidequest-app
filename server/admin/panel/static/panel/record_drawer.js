/* 支线管理后台：记录抽屉。
   记录列表点「查看」→ 右侧滑入抽屉，展示记录内容与媒体（媒体点击由 media_modal 灯箱接管）。
   关闭：✕ / 点击遮罩 / Esc（灯箱打开时 Esc 先关灯箱）。 */
(function () {
    'use strict';

    var BACKDROP_ID = 'sq-record-backdrop';
    var DRAWER_ID = 'sq-record-drawer';
    var BODY_ID = 'sq-record-body';
    var openToken = 0;

    function ensureShell() {
        if (document.getElementById(DRAWER_ID)) {
            return;
        }
        var backdrop = document.createElement('div');
        backdrop.id = BACKDROP_ID;
        backdrop.setAttribute('data-open', '');

        var drawer = document.createElement('aside');
        drawer.id = DRAWER_ID;
        drawer.setAttribute('data-open', '');
        drawer.innerHTML =
            '<div class="sqr-head">' +
            '<h2>记录详情</h2>' +
            '<button type="button" class="sqr-close" data-sqr-close aria-label="关闭">✕</button>' +
            '</div>' +
            '<div class="sqr-body" id="' + BODY_ID + '"></div>';

        document.body.appendChild(backdrop);
        document.body.appendChild(drawer);
    }

    function openDrawer(url) {
        ensureShell();
        var backdrop = document.getElementById(BACKDROP_ID);
        var drawer = document.getElementById(DRAWER_ID);
        var body = document.getElementById(BODY_ID);
        backdrop.setAttribute('data-open', '1');
        drawer.setAttribute('data-open', '1');
        body.innerHTML = '<div class="sqr-loading">载入中…</div>';
        var token = ++openToken;
        fetch(url, { headers: { 'Accept': 'text/html' } })
            .then(function (response) {
                if (!response.ok) {
                    throw new Error('HTTP ' + response.status);
                }
                return response.text();
            })
            .then(function (html) {
                if (token === openToken) {
                    body.innerHTML = html;
                }
            })
            .catch(function () {
                if (token === openToken) {
                    body.innerHTML = '<div class="sqr-error">记录加载失败，请稍后重试。</div>';
                }
            });
    }

    function closeDrawer() {
        var drawer = document.getElementById(DRAWER_ID);
        if (!drawer || drawer.getAttribute('data-open') !== '1') {
            return;
        }
        openToken++;
        drawer.setAttribute('data-open', '');
        var backdrop = document.getElementById(BACKDROP_ID);
        if (backdrop) {
            backdrop.setAttribute('data-open', '');
        }
    }

    document.addEventListener('click', function (event) {
        var target = event.target;
        if (!target || !target.closest) {
            return;
        }
        var trigger = target.closest('[data-sq-record]');
        if (trigger) {
            event.preventDefault();
            var url = trigger.getAttribute('data-sq-record-url');
            if (url) {
                openDrawer(url);
            }
            return;
        }
        if (target.closest('[data-sqr-close]')) {
            closeDrawer();
            return;
        }
        if (target.id === BACKDROP_ID) {
            closeDrawer();
        }
    });

    // 捕获阶段在 window 上监听：保证先于 media_modal 的 Esc 处理（document 冒泡）执行，
    // 灯箱打开时 Esc 只关灯箱、不关抽屉；再按一次才关抽屉。
    window.addEventListener('keydown', function (event) {
        if (event.key !== 'Escape') {
            return;
        }
        if (document.getElementById('sq-media-modal')) {
            return;
        }
        closeDrawer();
    }, true);

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', ensureShell);
    } else {
        ensureShell();
    }
})();
