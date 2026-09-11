# -*- Mode: makefile-gmake; tab-width: 4; indent-tabs-mode: t -*-
#
# This file is part of the LibreOffice project.
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This file incorporates work covered by the following license notice:
#
#   Licensed to the Apache Software Foundation (ASF) under one or more
#   contributor license agreements. See the NOTICE file distributed
#   with this work for additional information regarding copyright
#   ownership. The ASF licenses this file to you under the Apache
#   License, Version 2.0 (the "License"); you may not use this file
#   except in compliance with the License. You may obtain a copy of
#   the License at http://www.apache.org/licenses/LICENSE-2.0 .
#

$(eval $(call gb_Module_Module,writerperfect))

# AISPEC: wpftdraw/wpftimpress are gated on their externals rather than on the
# Impress strip flag. wpftdraw needs cdr/freehand/mspub/zmf/pagemaker/qxp/visio
# and wpftimpress needs etonyek -- all legacy import formats, none of them ODF
# or OOXML. --enable-wasm-strip sets test_lib<x>=no for every one of them, so
# re-enabling Impress via the strip flag alone pulls in libraries whose tarballs
# were never fetched ("depend(s) on package libetonyek which does not exist").
# Keying off BUILD_TYPE leaves a normal build unchanged, since CDR and ETONYEK
# are present there.
$(eval $(call gb_Module_add_targets,writerperfect,\
	$(if $(filter CDR,$(BUILD_TYPE)),Library_wpftdraw) \
	$(if $(filter ETONYEK,$(BUILD_TYPE)),Library_wpftimpress) \
	$(if $(ENABLE_WASM_STRIP_CALC),, \
	Library_wpftcalc \
	) \
	$(if $(ENABLE_WASM_STRIP_WRITER),, \
	Library_wpftwriter \
    ) \
	Library_writerperfect \
	UIConfig_writerperfect \
))

$(eval $(call gb_Module_add_l10n_targets,writerperfect,\
	AllLangMoTarget_wpt \
))

$(eval $(call gb_Module_add_check_targets,writerperfect,\
	CppunitTest_writerperfect_stream \
	CppunitTest_writerperfect_wpftimport \
))

$(eval $(call gb_Module_add_slowcheck_targets,writerperfect,\
	CppunitTest_writerperfect_calc \
	CppunitTest_writerperfect_draw \
	$(if $(SYSTEM_EPUBGEN),,CppunitTest_writerperfect_epubexport) \
	CppunitTest_writerperfect_import \
	CppunitTest_writerperfect_impress \
	CppunitTest_writerperfect_writer \
	Library_wpftqahelper \
))

$(eval $(call gb_Module_add_uicheck_targets,writerperfect,\
    UITest_writerperfect_epubexport \
))

# screenshots
$(eval $(call gb_Module_add_screenshot_targets,writerperfect,\
    CppunitTest_writerperfect_dialogs_test \
))
# vim: set noet sw=4 ts=4:
