/*
 *  Engrampa
 *
 *  Copyright (C) 2004 Free Software Foundation, Inc.
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU General Public
 *  License as published by the Free Software Foundation; either
 *  version 2 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Library General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public
 *  License along with this library; if not, write to the Free
 *  Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA.
 *
 *  Author: Paolo Bacchilega <paobac@cvs.mate.org>
 *
 */

#include <config.h>
#include <string.h>
#include <time.h>
#include <glib/gi18n-lib.h>
#include <gio/gio.h>
#include <libcaja-extension/caja-extension-types.h>
#include <libcaja-extension/caja-file-info.h>
#include <libcaja-extension/caja-menu-provider.h>
#include "caja-engrampa.h"

static GObjectClass *parent_class;

static void
extract_to_callback (CajaMenuItem *item,
		     gpointer          user_data)
{
	GList            *files, *scan;
	char             *default_dir;
	char             *quoted_default_dir;
	GString          *cmd;

	files = g_object_get_data (G_OBJECT (item), "files");
	default_dir = caja_file_info_get_parent_uri (files->data);
	quoted_default_dir = g_shell_quote (default_dir);

	cmd = g_string_new ("engrampa");
	g_string_append_printf(cmd," --default-dir=%s --extract", quoted_default_dir);

	for (scan = files; scan; scan = scan->next) {
		char *uri, *quoted_uri;

		uri = caja_file_info_get_uri (scan->data);
		quoted_uri = g_shell_quote (uri);
		g_string_append_printf (cmd, " %s", quoted_uri);
		g_free (uri);
		g_free (quoted_uri);
	}

#ifdef MATE_ENABLE_DEBUG
	g_print ("EXEC: %s\n", cmd->str);
#endif

	g_spawn_command_line_async (cmd->str, NULL);

	g_string_free (cmd, TRUE);
	g_free (default_dir);
	g_free (quoted_default_dir);
}

static void
extract_here_callback (CajaMenuItem *item,
		       gpointer          user_data)
{
	GList            *files, *scan;
	GString          *cmd;

	files = g_object_get_data (G_OBJECT (item), "files");

	cmd = g_string_new ("engrampa --extract-here");

	for (scan = files; scan; scan = scan->next) {
		CajaFileInfo *file = scan->data;
		char *uri, *quoted_uri;

		uri = caja_file_info_get_uri (file);
		quoted_uri = g_shell_quote (uri);
		g_string_append_printf (cmd, " %s", quoted_uri);
		g_free (uri);
		g_free (quoted_uri);
	}

	g_spawn_command_line_async (cmd->str, NULL);

#ifdef MATE_ENABLE_DEBUG
	g_print ("EXEC: %s\n", cmd->str);
#endif

	g_string_free (cmd, TRUE);
}

static void
add_callback (CajaMenuItem *item,
              gpointer      user_data)
{
	GList     *files, *scan;
	char      *uri, *dir;
	char      *quoted_dir;
	GString   *cmd;

	files = g_object_get_data (G_OBJECT (item), "files");
	uri = caja_file_info_get_uri (files->data);
	dir = g_path_get_dirname (uri);
	quoted_dir = g_shell_quote (dir);

	cmd = g_string_new ("engrampa");
	g_string_append_printf (cmd," --default-dir=%s --add", quoted_dir);

	g_free (uri);
	g_free (dir);
	g_free (quoted_dir);

	for (scan = files; scan; scan = scan->next) {
		char *quoted_uri;

		uri = caja_file_info_get_uri (scan->data);
		quoted_uri = g_shell_quote (uri);
		g_string_append_printf (cmd, " %s", quoted_uri);
		g_free (uri);
		g_free (quoted_uri);
	}

	g_spawn_command_line_async (cmd->str, NULL);

	g_string_free (cmd, TRUE);
}

/* --instant-add [--encrypt]: 一步到位压缩(BandiZip 式模板命名 /
 * WinRAR 式预设密码),实现见 engrampa 的 dlg-batch-add.c */
static void
add_instant_callback (CajaMenuItem *item,
		      gpointer      user_data)
{
	GList     *files, *scan;
	gboolean   encrypt = GPOINTER_TO_INT (user_data);
	char      *uri, *dir, *quoted_dir;
	GString   *cmd;

	files = g_object_get_data (G_OBJECT (item), "files");
	uri = caja_file_info_get_uri (files->data);
	dir = g_path_get_dirname (uri);
	quoted_dir = g_shell_quote (dir);

	cmd = g_string_new ("engrampa");
	g_string_append_printf (cmd, " --default-dir=%s --instant-add", quoted_dir);
	if (encrypt)
		g_string_append (cmd, " --encrypt");

	g_free (uri);
	g_free (dir);
	g_free (quoted_dir);

	for (scan = files; scan; scan = scan->next) {
		char *quoted_uri;

		uri = caja_file_info_get_uri (scan->data);
		quoted_uri = g_shell_quote (uri);
		g_string_append_printf (cmd, " %s", quoted_uri);
		g_free (uri);
		g_free (quoted_uri);
	}

	g_spawn_command_line_async (cmd->str, NULL);

	g_string_free (cmd, TRUE);
}

/* ---- 一步到位压缩的菜单标签支持:与 src/naming-template.c 同义的
 * 小型展开(扩展模块独立编译,不便链接主程序源文件) ---- */

static gboolean
is_strftime_spec_char (char c)
{
	return (c != '\0')
		&& (strchr ("aAbBcCdDeEFgGhHIjklmMnprRsStTuUVwWxXyYzZ+%", c) != NULL);
}

static char *
naming_template_expand (const char  *template,
			const char  *name)
{
	GString    *timed;
	GString    *final_str;
	const char *p;
	const char *q;
	const char *hit;
	time_t      now;
	struct tm   tm_now;

	if ((template == NULL) || (*template == '\0'))
		return g_strdup (name != NULL ? name : "");

	now = time (NULL);
	localtime_r (&now, &tm_now);

	timed = g_string_sized_new (strlen (template) + 32);
	for (p = template; *p != '\0'; p++) {
		if ((*p == '%') && is_strftime_spec_char (p[1])) {
			char fmt[3];
			char buf[128];

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

	final_str = g_string_sized_new (timed->len + strlen (name != NULL ? name : ""));
	q = timed->str;
	while ((hit = strstr (q, "${NAME}")) != NULL) {
		g_string_append_len (final_str, q, hit - q);
		if (name != NULL)
			g_string_append (final_str, name);
		q = hit + strlen ("${NAME}");
	}
	g_string_append (final_str, q);

	g_string_free (timed, TRUE);
	return g_string_free (final_str, FALSE);
}

/* ${NAME} 的语义与主程序一致: 单文件取基名去扩展名,多选取父目录名 */
static char *
selection_base_name (GList *files)
{
	char *uri;
	char *name;
	char *dot;

	uri = caja_file_info_get_uri (files->data);
	if (files->next != NULL) {
		char *dir = g_path_get_dirname (uri);
		name = g_path_get_basename (dir);
		g_free (dir);
	}
	else
		name = g_path_get_basename (uri);
	g_free (uri);

	if (files->next == NULL) {
		dot = strrchr (name, '.');
		if ((dot != NULL) && (dot != name) && (strlen (dot) < 10)) {
			char *stripped = g_strndup (name, dot - name);
			g_free (name);
			name = stripped;
		}
	}

	return name;
}

/* 模板名若不带任何已知压缩扩展名,展示时补上默认扩展名 */
static const char *known_archive_exts[] = {
	".zip", ".7z", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz",
	".tar.bz2", ".tbz2", ".tar.lz", ".tar.lzma", ".tar.Z", ".rar",
	".lzh", ".lha", ".arj", ".zoo", ".cpio", ".rpm", ".deb", NULL
};

static char *
preview_archive_name (const char *expanded,
		      const char *default_ext)
{
	int i;

	for (i = 0; known_archive_exts[i] != NULL; i++) {
		if (g_str_has_suffix (expanded, known_archive_exts[i]))
			return g_strdup (expanded);
	}
	return g_strconcat (expanded, default_ext, NULL);
}

static struct {
	const char *mime_type;
	gboolean    is_compressed;
} archive_mime_types[] = {
		{ "application/vnd.debian.binary-package", TRUE },
		{ "application/vnd.ms-cab-compressed", TRUE },
		{ "application/epub+zip", TRUE },
		{ "application/x-7z-compressed", TRUE },
		{ "application/x-7z-compressed-tar", TRUE },
		{ "application/x-ace", TRUE },
		{ "application/x-alz", TRUE },
		{ "application/x-arc", TRUE },
		{ "application/x-archive", TRUE },
		{ "application/x-arj", TRUE },
		{ "application/x-brotli", TRUE },
		{ "application/x-brotli-compressed-tar", TRUE },
		{ "application/x-bzip", TRUE },
		{ "application/x-bzip-compressed-tar", TRUE },
		{ "application/x-bzip1", TRUE },
		{ "application/x-bzip1-compressed-tar", TRUE },
		{ "application/x-cbr", TRUE },
		{ "application/x-cbz", TRUE },
		{ "application/x-cd-image", FALSE },
		{ "application/x-compress", TRUE },
		{ "application/x-compressed-tar", TRUE },
		{ "application/x-cpio", TRUE },
		{ "application/x-ear", TRUE },
		{ "application/x-gtar", FALSE },
		{ "application/x-gzip", TRUE },
		{ "application/x-gzpostscript", TRUE },
		{ "application/x-java-archive", TRUE },
		{ "application/x-lha", TRUE },
		{ "application/x-lzh-compressed", TRUE },
		{ "application/x-lzip", TRUE },
		{ "application/x-lzip-compressed-tar", TRUE },
		{ "application/x-lzma", TRUE },
		{ "application/x-lzma-compressed-tar", TRUE },
		{ "application/x-lzop", TRUE },
		{ "application/x-lzop-compressed-tar", TRUE },
		{ "application/x-ms-dos-executable", FALSE },
		{ "application/x-ms-wim", TRUE },
		{ "application/x-rar", TRUE },
		{ "application/x-rar-compressed", TRUE },
		{ "application/x-rpm", TRUE },
		{ "application/x-rzip", TRUE },
		{ "application/x-stuffit", TRUE },
		{ "application/x-tar", FALSE },
		{ "application/x-tarz", TRUE },
		{ "application/x-war", TRUE },
		{ "application/x-xz", TRUE },
		{ "application/x-xz-compressed-tar", TRUE },
		{ "application/x-zip", TRUE },
		{ "application/x-zip-compressed", TRUE },
		{ "application/x-zoo", TRUE },
		{ "application/zstd", TRUE },
		{ "application/x-zstd", TRUE },
		{ "application/x-zstd-compressed-tar", TRUE },
		{ "application/zip", TRUE },
		{ "multipart/x-zip", TRUE },
		{ NULL, FALSE }
};

typedef struct {
      gboolean is_archive;
      gboolean is_derived_archive;
      gboolean is_compressed_archive;
} FileMimeInfo;

static FileMimeInfo
get_file_mime_info (CajaFileInfo *file)
{
	FileMimeInfo file_mime_info;
	int          i;

	file_mime_info.is_archive = FALSE;
	file_mime_info.is_derived_archive = FALSE;
	file_mime_info.is_compressed_archive = FALSE;

	for (i = 0; archive_mime_types[i].mime_type != NULL; i++)
		if (caja_file_info_is_mime_type (file, archive_mime_types[i].mime_type)) {
			char *mime_type;
			char *content_type_mime_file;
			char *content_type_mime_compare;

			mime_type = caja_file_info_get_mime_type (file);

			content_type_mime_file = g_content_type_from_mime_type (mime_type);
			content_type_mime_compare = g_content_type_from_mime_type (archive_mime_types[i].mime_type);

			file_mime_info.is_archive = TRUE;
			file_mime_info.is_compressed_archive = archive_mime_types[i].is_compressed;
			if ((content_type_mime_file != NULL) && (content_type_mime_compare != NULL))
				file_mime_info.is_derived_archive = ! g_content_type_equals (content_type_mime_file, content_type_mime_compare);

			g_free (mime_type);
			g_free (content_type_mime_file);
			g_free (content_type_mime_compare);

			return file_mime_info;
		}

	return file_mime_info;
}

static gboolean
unsupported_scheme (CajaFileInfo *file)
{
	gboolean  result = FALSE;
	GFile    *location;
	char     *scheme;

	location = caja_file_info_get_location (file);
	scheme = g_file_get_uri_scheme (location);

	if (scheme != NULL) {
		const char *unsupported[] = { "trash", "computer", NULL };
		int         i;

		for (i = 0; unsupported[i] != NULL; i++)
			if (strcmp (scheme, unsupported[i]) == 0)
				result = TRUE;
	}

	g_free (scheme);
	g_object_unref (location);

	return result;
}

static GList *
caja_fr_get_file_items (CajaMenuProvider *provider,
			    GtkWidget            *window,
			    GList                *files)
{
	GList    *items = NULL;
	GList    *scan;
	gboolean  can_write = TRUE;
	gboolean  one_item;
	gboolean  one_archive = FALSE;
	gboolean  one_derived_archive = FALSE;
	gboolean  one_compressed_archive = FALSE;
	gboolean  all_archives = TRUE;
	gboolean  all_archives_derived = TRUE;
	gboolean  all_archives_compressed = TRUE;

	if (files == NULL)
		return NULL;

	if (unsupported_scheme ((CajaFileInfo *) files->data))
		return NULL;

	for (scan = files; scan; scan = scan->next) {
		CajaFileInfo *file = scan->data;
		FileMimeInfo file_mime_info;

		file_mime_info = get_file_mime_info (file);

		if (all_archives && ! file_mime_info.is_archive)
			all_archives = FALSE;

		if (all_archives_compressed && file_mime_info.is_archive && ! file_mime_info.is_compressed_archive)
			all_archives_compressed = FALSE;

		if (all_archives_derived && file_mime_info.is_archive && ! file_mime_info.is_derived_archive)
			all_archives_derived = FALSE;

		if (can_write) {
			CajaFileInfo *parent;

			parent = caja_file_info_get_parent_info (file);
 			can_write = caja_file_info_can_write (parent);
			g_object_unref (parent);
		}
	}

	/**/

	one_item = (files != NULL) && (files->next == NULL);
	one_archive = one_item && all_archives;
	one_derived_archive = one_archive && all_archives_derived;
	one_compressed_archive = one_archive && all_archives_compressed;

	if (all_archives && can_write) {
		CajaMenuItem *item;

		item = caja_menu_item_new ("CajaFr::extract_here",
					       _("Extract Here"),
					       /* Translators: the current position is the current folder */
					       _("Extract the selected archive to the current position"),
					       "drive-harddisk");
		g_signal_connect (item,
				  "activate",
				  G_CALLBACK (extract_here_callback),
				  provider);
		g_object_set_data_full (G_OBJECT (item),
					"files",
					caja_file_info_list_copy (files),
					(GDestroyNotify) caja_file_info_list_free);

		items = g_list_append (items, item);
	}
	if (all_archives) {
		CajaMenuItem *item;

		item = caja_menu_item_new ("CajaFr::extract_to",
					       _("Extract To..."),
					       _("Extract the selected archive"),
					       "drive-harddisk");
		g_signal_connect (item,
				  "activate",
				  G_CALLBACK (extract_to_callback),
				  provider);
		g_object_set_data_full (G_OBJECT (item),
					"files",
					caja_file_info_list_copy (files),
					(GDestroyNotify) caja_file_info_list_free);

		items = g_list_append (items, item);

	}

	if (! one_compressed_archive || one_derived_archive) {
		CajaMenuItem *item;

		item = caja_menu_item_new ("CajaFr::add",
					       _("Compress..."),
					       _("Create a compressed archive with the selected objects"),
					       "package-x-generic");
		g_signal_connect (item,
				  "activate",
				  G_CALLBACK (add_callback),
				  provider);
		g_object_set_data_full (G_OBJECT (item),
					"files",
					caja_file_info_list_copy (files),
					(GDestroyNotify) caja_file_info_list_free);

		items = g_list_append (items, item);

		/* 一步到位两项: 按命名模板直接压缩 / 加密压缩(预设密码)。
		 * 标签随当前选择实时展开模板(如"压缩为 报告【2026_10_25_21_49_32】.zip")。 */
		{
			GSettings *settings;
			char      *tmpl, *def_ext, *base, *expanded, *preview, *label;

			settings = g_settings_new ("org.mate.engrampa.dialogs.batch-add");
			tmpl = g_settings_get_string (settings, "naming-template");
			def_ext = g_settings_get_string (settings, "default-extension");
			base = selection_base_name (files);
			expanded = naming_template_expand (tmpl, base);
			preview = preview_archive_name (expanded, def_ext);

			label = g_strdup_printf (_("Compress to %s"), preview);
			item = caja_menu_item_new ("CajaFr::add_template",
						   label,
						   _("Create an archive named from the naming template, without a dialog"),
						   "package-x-generic");
			g_free (label);
			g_signal_connect (item,
					  "activate",
					  G_CALLBACK (add_instant_callback),
					  GINT_TO_POINTER (FALSE));
			g_object_set_data_full (G_OBJECT (item),
						"files",
						caja_file_info_list_copy (files),
						(GDestroyNotify) caja_file_info_list_free);
			items = g_list_append (items, item);

			item = caja_menu_item_new ("CajaFr::add_encrypted",
						   _("Compress to Encrypted Archive"),
						   _("Create an archive with the preset password, without a dialog"),
						   "package-x-generic");
			g_signal_connect (item,
					  "activate",
					  G_CALLBACK (add_instant_callback),
					  GINT_TO_POINTER (TRUE));
			g_object_set_data_full (G_OBJECT (item),
						"files",
						caja_file_info_list_copy (files),
						(GDestroyNotify) caja_file_info_list_free);
			items = g_list_append (items, item);

			g_free (preview);
			g_free (expanded);
			g_free (base);
			g_free (tmpl);
			g_free (def_ext);
			g_object_unref (settings);
		}
	}

	return items;
}

static void
caja_fr_menu_provider_iface_init (CajaMenuProviderIface *iface)
{
	iface->get_file_items = caja_fr_get_file_items;
}

static void
caja_fr_instance_init (CajaFr *fr)
{
}

static void
caja_fr_class_init (CajaFrClass *class)
{
	parent_class = g_type_class_peek_parent (class);
}

static GType fr_type = 0;

GType
caja_fr_get_type (void)
{
	return fr_type;
}

void
caja_fr_register_type (GTypeModule *module)
{
	static const GTypeInfo info = {
		sizeof (CajaFrClass),
		(GBaseInitFunc) NULL,
		(GBaseFinalizeFunc) NULL,
		(GClassInitFunc) caja_fr_class_init,
		NULL,
		NULL,
		sizeof (CajaFr),
		0,
		(GInstanceInitFunc) caja_fr_instance_init,
		NULL
	};

	static const GInterfaceInfo menu_provider_iface_info = {
		(GInterfaceInitFunc) caja_fr_menu_provider_iface_init,
		NULL,
		NULL
	};

	fr_type = g_type_module_register_type (module,
					       G_TYPE_OBJECT,
					       "CajaEngrampa",
					       &info, 0);

	g_type_module_add_interface (module,
				     fr_type,
				     CAJA_TYPE_MENU_PROVIDER,
				     &menu_provider_iface_info);
}
