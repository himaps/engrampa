/* -*- Mode: C++; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * Engrampa 的 peony-qt(UKUI 文件管理器)右键菜单插件
 *
 * Copyright (C) 2026 Free Software Foundation, Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

#include "peony-engrampa-plugin.h"

#include <QProcess>
#include <QUrl>

#include <ctime>

/*
 * 注意: 本插件不 include glib/gio —— Qt 的 signals 宏会与
 * gdbusintrospection.h 的 signals 成员冲突(qobjectdefs.h 定义
 * #define signals Q_SIGNALS)。gsettings 读取经 QProcess 调 CLI 完成。
 */

/* ---------- 与 engrampa 主程序 src/naming-template.c 同义的展开 ---------- */

static QString
expand_template (const QString &tmpl, const QString &name)
{
	QByteArray  t = tmpl.toUtf8 ();
	char        buf[4096];
	time_t      now = time (NULL);
	struct tm   tmv;

	localtime_r (&now, &tmv);
	if (strftime (buf, sizeof (buf), t.constData (), &tmv) > 0)
		return QString::fromUtf8 (buf).replace (QStringLiteral ("${NAME}"), name);
	return name;
}

/* gsettings get 经 CLI:输出形如 'value'(带单引号与换行) */
static QString
gsettings_get_string (const char *key)
{
	QProcess   p;
	QString    out;
	QString    v;

	p.start (QStringLiteral ("gsettings"),
		 QStringList () << QStringLiteral ("get")
				<< QStringLiteral ("org.mate.engrampa.dialogs.batch-add")
				<< QLatin1String (key));
	if (! p.waitForStarted (2000) || ! p.waitForFinished (3000))
		return QString ();

	out = QString::fromUtf8 (p.readAllStandardOutput ()).trimmed ();
	if (out.size () >= 2 && out.startsWith (QLatin1Char ('\'')) && out.endsWith (QLatin1Char ('\'')))
		v = out.mid (1, out.size () - 2);
	else if (out.startsWith (QLatin1String ("@s ")))
		v = out.mid (3).trimmed ();
	else
		v = out;
	if (v.startsWith (QLatin1Char ('\'')) && v.endsWith (QLatin1Char ('\'')) && v.size () >= 2)
		v = v.mid (1, v.size () - 2);
	return v;
}

/* ${NAME} 语义与主程序一致: 单选取基名去扩展名,多选取父目录名 */
static QString
base_name_for (const QStringList &uris)
{
	QUrl first (uris.first ());

	if (uris.size () == 1) {
		QString fn = first.fileName ();
		int     dot = fn.lastIndexOf ('.');

		if ((dot > 0) && (fn.size () - dot < 10))
			fn.truncate (dot);
		return fn;
	}

	return first.adjusted (QUrl::RemoveFilename | QUrl::StripTrailingSlash).fileName ();
}

static bool
has_archive_ext (const QString &name)
{
	static const char *known[] = {
		".zip", ".7z", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz",
		".tar.bz2", ".tbz2", ".tar.lz", ".tar.lzma", ".tar.Z", ".rar",
		".lzh", ".lha", ".arj", ".zoo", ".cpio", ".rpm", ".deb", NULL
	};
	QString lower = name.toLower ();

	for (int i = 0; known[i] != NULL; ++i)
		if (lower.endsWith (QLatin1String (known[i])))
			return true;
	return false;
}

/* ---------- 插件主体 ---------- */

PeonyEngrampaPlugin::PeonyEngrampaPlugin (QObject *parent) : QObject (parent)
{
}

QList<QAction *>
PeonyEngrampaPlugin::menuActions (Peony::MenuPluginInterface::Types types,
				  const QString                   &uri,
				  const QStringList               &selectionUris)
{
	QList<QAction *> actions;

	if (! m_enabled || selectionUris.isEmpty ())
		return actions;

	if (! (types & (Peony::MenuPluginInterface::DirectoryView
			| Peony::MenuPluginInterface::DesktopWindow)))
		return actions;

	/* 单选且本身是压缩包 → 不注入(右键已有解压项) */
	if ((selectionUris.size () == 1)
	    && has_archive_ext (QUrl (selectionUris.first ()).fileName ()))
		return actions;

	QString tmpl    = gsettings_get_string ("naming-template");
	QString defExt  = gsettings_get_string ("default-extension");
	QString base    = base_name_for (selectionUris);
	QString name    = expand_template (tmpl.isEmpty () ? QStringLiteral ("${NAME}") : tmpl, base);
	QString shown   = name;
	QString parentDir = QUrl (selectionUris.first ())
				.adjusted (QUrl::RemoveFilename | QUrl::StripTrailingSlash)
				.toString ();

	if (! has_archive_ext (shown) && ! defExt.isEmpty ())
		shown = name + defExt;

	QStringList uris = selectionUris;

	QAction *instant = new QAction (QStringLiteral ("压缩为 %1").arg (shown), nullptr);
	instant->setIcon (QIcon::fromTheme (QStringLiteral ("package-x-generic")));
	connect (instant, &QAction::triggered, [uris, parentDir] () {
		QStringList args;

		args << ("--default-dir=" + parentDir) << "--instant-add" << uris;
		QProcess::startDetached (QStringLiteral ("engrampa"), args);
	});
	actions << instant;

	QAction *encrypted = new QAction (QStringLiteral ("压缩为加密压缩文件"), nullptr);
	encrypted->setIcon (QIcon::fromTheme (QStringLiteral ("package-x-generic")));
	connect (encrypted, &QAction::triggered, [uris, parentDir] () {
		QStringList args;

		args << ("--default-dir=" + parentDir) << "--instant-add" << "--encrypt" << uris;
		QProcess::startDetached (QStringLiteral ("engrampa"), args);
	});
	actions << encrypted;

	return actions;
}
