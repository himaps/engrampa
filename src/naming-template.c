/* -*- Mode: C; tab-width: 8; indent-tabs-mode: t; c-basic-offset: 8 -*- */

/*
 *  Engrampa
 *
 *  BandiZip-style naming template expansion.
 *
 *  Copyright (C) 2026 Free Software Foundation, Inc.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 */

#include <config.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <glib.h>
#include "naming-template.h"

static gboolean
is_strftime_spec (char c)
{
	return (c != '\0')
		&& (strchr ("aAbBcCdDeEFgGhHIjklmMnprRsStTuUVwWxXyYzZ+%", c) != NULL);
}

char *
naming_template_expand (const char  *template,
			const char  *name)
{
	GString    *timed;
	GString    *final;
	const char *p;
	const char *q;
	const char *hit;
	time_t      now;
	struct tm   tm_now;

	if ((template == NULL) || (*template == '\0'))
		return g_strdup (name != NULL ? name : "");

	now = time (NULL);
	localtime_r (&now, &tm_now);

	/* Pass 1: strftime 展开(不碰 ${NAME} 之外的字面内容) */
	timed = g_string_sized_new (strlen (template) + 32);
	for (p = template; *p != '\0'; p++) {
		if ((*p == '%') && is_strftime_spec (p[1])) {
			char  fmt[3];
			char  buf[128];

			fmt[0] = '%';
			fmt[1] = p[1];
			fmt[2] = '\0';
			if (strftime (buf, sizeof (buf), fmt, &tm_now) > 0) {
				g_string_append (timed, buf);
				p++;
			}
			else
				g_string_append_c (timed, *p);
		}
		else
			g_string_append_c (timed, *p);
	}

	/* Pass 2: ${NAME} 替换 */
	final = g_string_sized_new (timed->len + strlen (name != NULL ? name : ""));
	q = timed->str;
	while ((hit = strstr (q, "${NAME}")) != NULL) {
		g_string_append_len (final, q, hit - q);
		if (name != NULL)
			g_string_append (final, name);
		q = hit + strlen ("${NAME}");
	}
	g_string_append (final, q);

	g_string_free (timed, TRUE);
	return g_string_free (final, FALSE);
}
