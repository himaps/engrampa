/* -*- Mode: C; tab-width: 8; indent-tabs-mode: t; c-basic-offset: 8 -*- */

/*
 *  Engrampa
 *
 *  BandiZip-style naming template expansion.
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef NAMING_TEMPLATE_H
#define NAMING_TEMPLATE_H

/*
 * 展开命名模板:
 *   ${NAME}  -> name 参数(调用方决定语义:文件基名/父目录名等)
 *   其余部分按 strftime 以当前本地时间展开(%Y %m %d %H %M_%S ...),
 *   %% 输出字面 %。
 * 先做时间展开、再替换 ${NAME},这样 name 中的 % 不会被误当时间符。
 * template 为空/NULL 时等价于直接返回 name 的副本。
 */
char * naming_template_expand (const char  *template,
			       const char  *name);

#endif /* NAMING_TEMPLATE_H */
