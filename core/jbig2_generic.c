/*
 * jbig2_generic.c — собственный lossless-кодер JBIG2 (generic region, MQ-арифметика).
 *
 * Без зависимостей: только libc. Один и тот же файл подключается
 *   - в Python через ctypes (прототип),
 *   - в Flutter через dart:ffi (Android NDK) — следующий этап.
 *
 * Что делает: кодирует 1-битную картинку (1 = чёрный) как
 * «immediate generic region», шаблон 0, с типовым предсказанием строк (TPGDON).
 * Это режим БЕЗ потерь: декодер восстанавливает каждый пиксель точно.
 * Символьный режим (подстановка похожих букв) намеренно не используется.
 *
 * Стандарт: ITU-T T.88 (JBIG2), приложение E (MQ-кодер), 6.2 (generic region).
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ---------- MQ-кодер (T.88, приложение E) ---------- */

static const struct { uint16_t qe; uint8_t nmps, nlps, sw; } QE[47] = {
 {0x5601, 1, 1,1},{0x3401, 2, 6,0},{0x1801, 3, 9,0},{0x0AC1, 4,12,0},
 {0x0521, 5,29,0},{0x0221,38,33,0},{0x5601, 7, 6,1},{0x5401, 8,14,0},
 {0x4801, 9,14,0},{0x3801,10,14,0},{0x3001,11,17,0},{0x2401,12,18,0},
 {0x1C01,13,20,0},{0x1601,29,21,0},{0x5601,15,14,1},{0x5401,16,14,0},
 {0x5101,17,15,0},{0x4801,18,16,0},{0x3801,19,17,0},{0x3401,20,18,0},
 {0x3001,21,19,0},{0x2801,22,19,0},{0x2401,23,20,0},{0x2201,24,21,0},
 {0x1C01,25,22,0},{0x1801,26,23,0},{0x1601,27,24,0},{0x1401,28,25,0},
 {0x1201,29,26,0},{0x1101,30,27,0},{0x0AC1,31,28,0},{0x09C1,32,29,0},
 {0x08A1,33,30,0},{0x0521,34,31,0},{0x0441,35,32,0},{0x02A1,36,33,0},
 {0x0221,37,34,0},{0x0141,38,35,0},{0x0111,39,36,0},{0x0085,40,37,0},
 {0x0049,41,38,0},{0x0025,42,39,0},{0x0015,43,40,0},{0x0009,44,41,0},
 {0x0005,45,42,0},{0x0001,45,43,0},{0x5601,46,46,0}
};

typedef struct {
    uint32_t a, c;
    int ct;
    uint8_t *buf;     /* buf[0] — служебный байт перед потоком */
    size_t bp, cap;
    int err;
    uint8_t idx[65536];
    uint8_t mps[65536];
} mq_t;

static void put(mq_t *e) {           /* BP += 1 с контролем размера */
    e->bp++;
    if (e->bp >= e->cap) {
        size_t ncap = e->cap * 2;
        uint8_t *nb = (uint8_t *)realloc(e->buf, ncap);
        if (!nb) { e->err = 1; e->bp--; return; }
        e->buf = nb; e->cap = ncap;
    }
    e->buf[e->bp] = 0;
}

static void byteout(mq_t *e) {
    if (e->buf[e->bp] == 0xFF) {
        put(e); e->buf[e->bp] = (uint8_t)(e->c >> 20); e->c &= 0xFFFFF; e->ct = 7;
    } else if (e->c < 0x8000000) {
        put(e); e->buf[e->bp] = (uint8_t)(e->c >> 19); e->c &= 0x7FFFF; e->ct = 8;
    } else {
        e->buf[e->bp]++;
        if (e->buf[e->bp] == 0xFF) {
            e->c &= 0x7FFFFFF;
            put(e); e->buf[e->bp] = (uint8_t)(e->c >> 20); e->c &= 0xFFFFF; e->ct = 7;
        } else {
            put(e); e->buf[e->bp] = (uint8_t)(e->c >> 19); e->c &= 0x7FFFF; e->ct = 8;
        }
    }
}

static void renorm(mq_t *e) {
    do {
        e->a <<= 1; e->c <<= 1; e->ct--;
        if (e->ct == 0) byteout(e);
    } while ((e->a & 0x8000) == 0);
}

static void encode_bit(mq_t *e, uint32_t cx, int d) {
    int i = e->idx[cx];
    uint32_t qe = QE[i].qe;
    if (d == e->mps[cx]) {                      /* CODEMPS */
        e->a -= qe;
        if ((e->a & 0x8000) == 0) {
            if (e->a < qe) e->a = qe; else e->c += qe;
            e->idx[cx] = QE[i].nmps;
            renorm(e);
        } else {
            e->c += qe;
        }
    } else {                                    /* CODELPS */
        e->a -= qe;
        if (e->a < qe) e->c += qe; else e->a = qe;
        if (QE[i].sw) e->mps[cx] = 1 - e->mps[cx];
        e->idx[cx] = QE[i].nlps;
        renorm(e);
    }
}

static void flush(mq_t *e) {
    uint32_t tempc = e->c + e->a;               /* SETBITS */
    e->c |= 0xFFFF;
    if (e->c >= tempc) e->c -= 0x8000;
    e->c <<= e->ct; byteout(e);
    e->c <<= e->ct; byteout(e);
    if (e->buf[e->bp] != 0xFF) { put(e); e->buf[e->bp] = 0xFF; }
    put(e); e->buf[e->bp] = 0xAC;               /* маркер конца MQ-потока */
}

/* ---------- generic region, шаблон 0 ---------- */

#define PX(r, x) ((x) >= 0 && (x) < w && (r) ? (r)[x] : 0)

/*
 * img: w*h байт, 0 = белый, 1 = чёрный.
 * out: указатель на выделенный буфер с MQ-данными (освобождать jbig2_free).
 * Возвращает длину или -1 при ошибке.
 *
 * Порядок битов контекста совпадает со стандартом (jbig2dec / pdf.js),
 * это обязательно, потому что TPGDON использует фиксированный контекст 0x9B25.
 * Пиксели AT — номинальные: A1(3,-1) A2(-3,-1) A3(2,-2) A4(-2,-2).
 */
long jbig2_encode_generic(const uint8_t *img, int w, int h, int tpgdon, uint8_t **out) {
    mq_t *e = (mq_t *)calloc(1, sizeof(mq_t));
    if (!e) return -1;
    e->cap = 1 << 16;
    e->buf = (uint8_t *)malloc(e->cap);
    if (!e->buf) { free(e); return -1; }
    e->buf[0] = 0; e->bp = 0;
    e->a = 0x8000; e->c = 0; e->ct = 12;

    int ltp = 0;
    for (int y = 0; y < h && !e->err; y++) {
        const uint8_t *r0 = img + (size_t)y * w;
        const uint8_t *r1 = y >= 1 ? r0 - w : NULL;
        const uint8_t *r2 = y >= 2 ? r0 - 2 * (size_t)w : NULL;

        if (tpgdon) {
            int same;
            if (r1) same = memcmp(r0, r1, (size_t)w) == 0;
            else { same = 1; for (int x = 0; x < w; x++) if (r0[x]) { same = 0; break; } }
            encode_bit(e, 0x9B25, same ^ ltp);
            ltp = same;
            if (same) continue;                  /* строка = предыдущей, пропускаем */
        }

        for (int x = 0; x < w; x++) {
            uint32_t cx =
                (PX(r2, x - 2) << 15) | (PX(r2, x - 1) << 14) | (PX(r2, x) << 13) |
                (PX(r2, x + 1) << 12) | (PX(r2, x + 2) << 11) |
                (PX(r1, x - 3) << 10) | (PX(r1, x - 2) << 9) | (PX(r1, x - 1) << 8) |
                (PX(r1, x) << 7) | (PX(r1, x + 1) << 6) | (PX(r1, x + 2) << 5) |
                (PX(r1, x + 3) << 4) |
                (PX(r0, x - 4) << 3) | (PX(r0, x - 3) << 2) | (PX(r0, x - 2) << 1) |
                PX(r0, x - 1);
            encode_bit(e, cx, r0[x]);
        }
    }
    if (!e->err) flush(e);
    if (e->err) { free(e->buf); free(e); return -1; }

    /* buf[0] — служебный байт, данные начинаются с buf[1] */
    long n = (long)e->bp;
    uint8_t *res = (uint8_t *)malloc(n > 0 ? (size_t)n : 1);
    if (!res) { free(e->buf); free(e); return -1; }
    memcpy(res, e->buf + 1, (size_t)n);
    free(e->buf); free(e);
    *out = res;
    return n;
}

void jbig2_free(uint8_t *p) { free(p); }
