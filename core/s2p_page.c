/*
 * s2p_page.c — страница скана -> готовый JBIG2-поток для PDF.
 *
 * Общий код для прототипа на Python (ctypes) и приложения на Flutter (dart:ffi):
 *   1. RGBA/серый -> серый
 *   2. адаптивная бинаризация Sauvola (скользящее окно, память O(ширина))
 *   3. кодирование JBIG2 generic region без потерь (jbig2_generic.c)
 *   4. упаковка в сегменты JBIG2 (встраиваемый формат для фильтра /JBIG2Decode)
 *
 * Только libc, без сторонних библиотек.
 */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

long jbig2_encode_generic(const uint8_t *img, int w, int h, int tpgdon, uint8_t **out);
void jbig2_free(uint8_t *p);

/* Память для вызывающей стороны (Dart), чтобы не тянуть package:ffi. */
void *s2p_alloc(long n) { return malloc(n > 0 ? (size_t)n : 1); }
void s2p_free(void *p) { free(p); }

/* channels: 1 (серый), 3 (RGB) или 4 (RGBA). Коэффициенты как в Pillow (ITU-R 601). */
static uint8_t *to_gray(const uint8_t *px, int w, int h, int channels) {
    size_t n = (size_t)w * h;
    uint8_t *g = (uint8_t *)malloc(n);
    if (!g) return NULL;
    if (channels == 1) { memcpy(g, px, n); return g; }
    for (size_t i = 0; i < n; i++) {
        const uint8_t *p = px + i * (size_t)channels;
        g[i] = (uint8_t)((p[0] * 299 + p[1] * 587 + p[2] * 114 + 500) / 1000);
    }
    return g;
}

/*
 * Sauvola: T = m * (1 + k * (s / 128 - 1)), окно window x window (нечётное),
 * края — повтор крайних пикселей. out: 1 = чёрный.
 */
int s2p_binarize(const uint8_t *gray, int w, int h, int window, double k, uint8_t *out) {
    if (window < 3) window = 3;
    if (!(window & 1)) window++;
    int r = window / 2;
    double n = (double)window * window;

    /* суммы по столбцам в текущей полосе строк [y-r, y+r] */
    uint32_t *cs = (uint32_t *)calloc((size_t)w, sizeof(uint32_t));
    uint64_t *cq = (uint64_t *)calloc((size_t)w, sizeof(uint64_t));
    if (!cs || !cq) { free(cs); free(cq); return -1; }

#define ROW(yy) (gray + (size_t)((yy) < 0 ? 0 : ((yy) >= h ? h - 1 : (yy))) * w)

    for (int yy = -r; yy <= r; yy++) {
        const uint8_t *row = ROW(yy);
        for (int x = 0; x < w; x++) { cs[x] += row[x]; cq[x] += (uint32_t)row[x] * row[x]; }
    }

    for (int y = 0; y < h; y++) {
        if (y > 0) {
            const uint8_t *add = ROW(y + r), *sub = ROW(y - r - 1);
            for (int x = 0; x < w; x++) {
                cs[x] += add[x]; cs[x] -= sub[x];
                cq[x] += (uint32_t)add[x] * add[x]; cq[x] -= (uint32_t)sub[x] * sub[x];
            }
        }
        /* горизонтальное скользящее окно по суммам столбцов */
        uint64_t s = 0, q = 0;
        for (int xx = -r; xx <= r; xx++) {
            int c = xx < 0 ? 0 : (xx >= w ? w - 1 : xx);
            s += cs[c]; q += cq[c];
        }
        const uint8_t *row = gray + (size_t)y * w;
        uint8_t *o = out + (size_t)y * w;
        for (int x = 0; x < w; x++) {
            if (x > 0) {
                int ca = x + r >= w ? w - 1 : x + r;
                int cd = x - r - 1 < 0 ? 0 : x - r - 1;
                s += cs[ca]; s -= cs[cd];
                q += cq[ca]; q -= cq[cd];
            }
            double m = (double)s / n;
            double var = (double)q / n - m * m;
            double sd = var > 0 ? sqrt(var) : 0;
            double t = m * (1.0 + k * (sd / 128.0 - 1.0));
            o[x] = (double)row[x] < t ? 1 : 0;
        }
    }
#undef ROW
    free(cs); free(cq);
    return 0;
}

static uint8_t *put32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
    return p + 4;
}

/* Заголовок сегмента: номер, тип, 0 ссылок, страница 1, длина данных. 11 байт. */
static uint8_t *seg_header(uint8_t *p, uint32_t num, uint8_t type, uint32_t len) {
    p = put32(p, num);
    *p++ = type & 0x3F;
    *p++ = 0x00;
    *p++ = 1;
    return put32(p, len);
}

/* 1-битная страница -> сегменты JBIG2: информация о странице + immediate generic region. */
long s2p_jbig2_stream(const uint8_t *bitmap, int w, int h, int dpi, uint8_t **out) {
    uint8_t *mq = NULL;
    long mqlen = jbig2_encode_generic(bitmap, w, h, 1, &mq);
    if (mqlen < 0) return -1;

    const uint32_t page_len = 19, region_len = 17 + 1 + 8 + (uint32_t)mqlen;
    long total = 11 + page_len + 11 + region_len;
    uint8_t *buf = (uint8_t *)malloc((size_t)total);
    if (!buf) { jbig2_free(mq); return -1; }

    uint32_t ppm = (uint32_t)(dpi / 0.0254 + 0.5);   /* точек на метр */
    uint8_t *p = seg_header(buf, 0, 48, page_len);   /* page information */
    p = put32(p, (uint32_t)w); p = put32(p, (uint32_t)h);
    p = put32(p, ppm); p = put32(p, ppm);
    *p++ = 0x01;                                     /* страница кодируется без потерь */
    *p++ = 0; *p++ = 0;                              /* без полос */

    p = seg_header(p, 1, 38, region_len);            /* immediate generic region */
    p = put32(p, (uint32_t)w); p = put32(p, (uint32_t)h);
    p = put32(p, 0); p = put32(p, 0);
    *p++ = 0;                                        /* комбинирование OR */
    *p++ = 0x08;                                     /* MMR=0, шаблон 0, TPGDON=1 */
    static const int8_t at[8] = {3, -1, -3, -1, 2, -2, -2, -2};
    memcpy(p, at, 8); p += 8;
    memcpy(p, mq, (size_t)mqlen);
    jbig2_free(mq);

    *out = buf;
    return total;
}

/*
 * Полный путь для одной страницы: пиксели -> JBIG2-поток.
 * window <= 0: окно подбирается по DPI (41 px при 300 dpi).
 * bitmap_out (может быть NULL): сюда кладётся ч/б страница для проверки.
 */
long s2p_encode_page(const uint8_t *px, int w, int h, int channels, int dpi,
                     double k, int window, uint8_t **out, uint8_t *bitmap_out) {
    if (w <= 0 || h <= 0 || dpi <= 0) return -1;
    if (window <= 0) window = ((int)(dpi / 300.0 * 41)) | 1;

    uint8_t *gray = to_gray(px, w, h, channels);
    if (!gray) return -1;
    uint8_t *bm = bitmap_out ? bitmap_out : (uint8_t *)malloc((size_t)w * h);
    if (!bm) { free(gray); return -1; }

    long n = -1;
    if (s2p_binarize(gray, w, h, window, k, bm) == 0)
        n = s2p_jbig2_stream(bm, w, h, dpi, out);

    free(gray);
    if (!bitmap_out) free(bm);
    return n;
}
