/*
 * fbrender - render a PNG into an FbTerm slideshow background file.
 *
 * The patched FbTerm watches the output file and crossfades the
 * terminal background to it, without touching the text on screen.
 *
 * Output format (all little-endian u32):
 *   magic 0x31474246 ("FBG1"), width, height, transition, duration_ms
 *   followed by width*height pixels in XRGB (0x00RRGGBB).
 *
 * Transitions: 0 = none, 1 = crossfade, 2 = fade via black,
 *              3 = fade via white.
 *
 * Uses lodepng (from the bundled idump sources) for PNG decoding.
 * Build: gcc -O2 -std=gnu99 fbrender.c lodepng.c -o fbrender
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lodepng.h"

static void usage(void)
{
	fprintf(stderr,
		"usage: fbrender --size WxH --mode cover|fit --brightness N\n"
		"                --transition T --duration MS in.png out.fbg\n"
		"  --brightness  0..100 (100 = original image)\n"
		"  --transition  none|crossfade|black|white\n");
}

static int parse_size(const char *s, unsigned *w, unsigned *h)
{
	return sscanf(s, "%ux%u", w, h) == 2 && *w && *h;
}

/* bilinear sample of the decoded RGBA image at (fx, fy) */
static void sample(const unsigned char *img, unsigned sw, unsigned sh,
		   double fx, double fy, unsigned char out[4])
{
	if (fx < 0) fx = 0;
	if (fy < 0) fy = 0;
	if (fx > (double)sw - 1) fx = (double)sw - 1;
	if (fy > (double)sh - 1) fy = (double)sh - 1;
	unsigned x0 = (unsigned)fx, y0 = (unsigned)fy;
	unsigned x1 = x0 + 1 < sw ? x0 + 1 : x0;
	unsigned y1 = y0 + 1 < sh ? y0 + 1 : y0;
	double tx = fx - x0, ty = fy - y0;
	const unsigned char *p00 = img + ((size_t)y0 * sw + x0) * 4;
	const unsigned char *p10 = img + ((size_t)y0 * sw + x1) * 4;
	const unsigned char *p01 = img + ((size_t)y1 * sw + x0) * 4;
	const unsigned char *p11 = img + ((size_t)y1 * sw + x1) * 4;
	for (int c = 0; c < 4; c++) {
		double v = p00[c] * (1 - tx) * (1 - ty) + p10[c] * tx * (1 - ty)
			 + p01[c] * (1 - tx) * ty + p11[c] * tx * ty;
		out[c] = (unsigned char)(v + 0.5);
	}
}

int main(int argc, char **argv)
{
	unsigned tw = 0, th = 0, brightness = 100, duration = 800;
	int mode_cover = 1, transition = 1;
	const char *in = NULL, *out = NULL;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--size") && i + 1 < argc) {
			if (!parse_size(argv[++i], &tw, &th)) { usage(); return 2; }
		} else if (!strcmp(argv[i], "--mode") && i + 1 < argc) {
			const char *m = argv[++i];
			if (!strcmp(m, "cover")) mode_cover = 1;
			else if (!strcmp(m, "fit")) mode_cover = 0;
			else { usage(); return 2; }
		} else if (!strcmp(argv[i], "--brightness") && i + 1 < argc) {
			brightness = (unsigned)atoi(argv[++i]);
			if (brightness > 100) brightness = 100;
		} else if (!strcmp(argv[i], "--transition") && i + 1 < argc) {
			const char *t = argv[++i];
			if (!strcmp(t, "none")) transition = 0;
			else if (!strcmp(t, "crossfade")) transition = 1;
			else if (!strcmp(t, "black")) transition = 2;
			else if (!strcmp(t, "white")) transition = 3;
			else { usage(); return 2; }
		} else if (!strcmp(argv[i], "--duration") && i + 1 < argc) {
			duration = (unsigned)atoi(argv[++i]);
			if (duration > 10000) duration = 10000;
		} else if (argv[i][0] != '-' && !in) {
			in = argv[i];
		} else if (argv[i][0] != '-' && !out) {
			out = argv[i];
		} else {
			usage();
			return 2;
		}
	}
	if (!tw || !th || !in || !out) { usage(); return 2; }

	unsigned char *src = NULL;
	unsigned sw = 0, sh = 0;
	if (lodepng_decode32_file(&src, &sw, &sh, in)) {
		fprintf(stderr, "fbrender: cannot decode PNG: %s\n", in);
		return 1;
	}

	/* target rectangle of the scaled image (cover crops, fit pads) */
	double scale;
	if (mode_cover) {
		double a = (double)tw / sw, b = (double)th / sh;
		scale = a > b ? a : b;
	} else {
		double a = (double)tw / sw, b = (double)th / sh;
		scale = a < b ? a : b;
	}
	double dw = sw * scale, dh = sh * scale;
	double ox = ((double)tw - dw) / 2, oy = ((double)th - dh) / 2;

	FILE *f = fopen(out, "wb");
	if (!f) {
		fprintf(stderr, "fbrender: cannot write: %s\n", out);
		free(src);
		return 1;
	}
	unsigned head[5] = { 0x31474246u, tw, th, (unsigned)transition, duration };
	fwrite(head, 4, 5, f);

	for (unsigned y = 0; y < th; y++) {
		for (unsigned x = 0; x < tw; x++) {
			unsigned char px[4] = { 0, 0, 0, 255 };
			double sx = (x - ox) / scale, sy = (y - oy) / scale;
			if (sx >= 0 && sy >= 0 && sx < (double)sw && sy < (double)sh)
				sample(src, sw, sh, sx, sy, px);
			/* composite over black, then apply brightness */
			unsigned r = px[0] * px[3] / 255 * brightness / 100;
			unsigned g = px[1] * px[3] / 255 * brightness / 100;
			unsigned b = px[2] * px[3] / 255 * brightness / 100;
			unsigned v = (r << 16) | (g << 8) | b;
			fwrite(&v, 4, 1, f);
		}
	}
	fclose(f);
	free(src);
	return 0;
}
