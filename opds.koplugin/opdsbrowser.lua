local BD = require("ui/bidi")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Cache = require("cache")
local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local DownloadMgr = require("ui/downloadmgr")
local Notification = require("ui/widget/notification")
local OPDSParser = require("opdsparser")
local OPDSPSE = require("opdspse")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

-- luacheck: globals G_reader_settings

local function parseCSVList(str)
    local list = {}
    if str and str ~= "" then
        for entry in util.gsplit(str, ",") do
            local trimmed = util.trim(entry)
            if trimmed ~= "" then
                table.insert(list, trimmed)
            end
        end
    end
    return list
end

local function listHasEntries(list)
    return type(list) == "table" and #list > 0
end

local function listContainsText(list, text)
    if not listHasEntries(list) then return false end
    local lower_text = (text or ""):lower()
    for _, value in ipairs(list) do
        local needle = (value or ""):lower()
        if needle ~= "" and lower_text:find(needle, 1, true) then
            return true
        end
    end
    return false
end

local function listContainsCategory(list, entry)
    if not listHasEntries(list) or not entry or not entry.category then return false end
    local categories = entry.category
    if type(categories) == "string" then
        categories = { categories }
    elseif type(categories) == "table" and (categories.term or categories.label) then
        categories = { categories }
    elseif type(categories) ~= "table" then
        return false
    end
    for _, category in ipairs(categories) do
        local text
        if type(category) == "table" then
            text = category.term or category.label
        elseif type(category) == "string" then
            text = category
        end
        if text and listContainsText(list, text) then
            return true
        end
    end
    return false
end

local function redactURLForLog(value)
    if type(value) ~= "string" then return value end
    return value
        :gsub("^(https?://[^/@:]+):([^/@]+)@", "%1:…@")
        :gsub("([?&][^=]*[Kk]ey=)[^&]+", "%1…")
        :gsub("([?&][Tt]oken=)[^&]+", "%1…")
        :gsub("([?&][Pp]assword=)[^&]+", "%1…")
end

local function redirectDowngradeLocation(from_url, status_code, location)
    status_code = tonumber(status_code)
    if not location
        or not (status_code == 301 or status_code == 302 or status_code == 303
            or status_code == 307 or status_code == 308)
        or type(from_url) ~= "string"
        or not from_url:lower():match("^https://") then
        return nil
    end
    local absolute_location = url.absolute(from_url, location)
    if absolute_location and absolute_location:lower():match("^http://") then
        return absolute_location
    end
end

-- cache catalog parsed from feed xml
local CatalogCache = Cache:new{
    -- Make it 20 slots, with no storage space constraints
    slots = 20,
}

local OPDSBrowser = Menu:extend{
    catalog_type         = "application/atom%+xml",
    search_type          = "application/opensearchdescription%+xml",
    search_template_type = "application/atom%+xml",
    acquisition_rel      = "^http://opds%-spec%.org/acquisition",
    borrow_rel           = "http://opds-spec.org/acquisition/borrow",
    stream_rel           = "http://vaemendis.net/opds-pse/stream",
    facet_rel            = "http://opds-spec.org/facet",
    image_rel            = {
        ["http://opds-spec.org/image"] = true,
        ["http://opds-spec.org/cover"] = true, -- ManyBooks.net, not in spec
        ["x-stanza-cover-image"] = true,
    },
    thumbnail_rel        = {
        ["http://opds-spec.org/image/thumbnail"] = true,
        ["http://opds-spec.org/thumbnail"] = true, -- ManyBooks.net, not in spec
        ["x-stanza-cover-image-thumbnail"] = true,
    },

    root_catalog_title    = nil,
    root_catalog_username = nil,
    root_catalog_password = nil,
    facet_groups          = nil, -- Stores OPDS facet groups

    title_shrink_font_to_fit = true,
}

function OPDSBrowser:init()
    self.item_table = self:genItemTableFromRoot()
    self.catalog_title = nil
    self.title_bar_left_icon = "appbar.menu"
    self.onLeftButtonTap = function()
        self:showOPDSMenu()
    end
    self.facet_groups = nil -- Initialize facet groups storage
    Menu.init(self) -- call parent's init()
end

function OPDSBrowser:showOPDSMenu()
    local dialog
    local auto_sync_status = self._manager.settings.auto_sync and _("On") or _("Off")
    local last_sync = tonumber(self._manager.settings.last_sync_time) or 0
    local last_sync_text = last_sync > 0 and os.date("%Y-%m-%d %H:%M", last_sync) or _("Never")
    dialog = ButtonDialog:new{
        buttons = {
            {{
                    text = _("Add catalog"),
                    callback = function()
                        UIManager:close(dialog)
                        self:addEditCatalog()
                    end,
                    align = "left",
            }},
            {},
            {{
                text = _("Auto-sync: ") .. auto_sync_status,
                callback = function()
                    UIManager:close(dialog)
                    self._manager.settings.auto_sync = not self._manager.settings.auto_sync
                    self._manager.updated = true
                    if self._manager.settings.auto_sync then
                        self._manager:schedulePeriodicSync()
                        self._manager:registerAutoSyncEvents()
                    else
                        UIManager:unschedule(self._manager.periodic_sync_task)
                        self._manager:registerAutoSyncEvents()
                    end
                    UIManager:show(InfoMessage:new{
                        text = self._manager.settings.auto_sync and _("Auto-sync enabled") or _("Auto-sync disabled"),
                    })
                end,
                align = "left",
            }},
            {{
                text = _("Last sync: ") .. last_sync_text,
                enabled = false,
                align = "left",
            }},
            {},
            {{
                    text = _("Sync all catalogs"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self.sync_force = false
                            self:checkSyncDownload()
                        end)
                    end,
                    align = "left",
            }},
            {{
                    text = _("Force sync all catalogs"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self.sync_force = true
                            self:checkSyncDownload()
                        end)
                    end,
                    align = "left",
            }},
            {{
                    text = _("Set max number of files to sync"),
                    callback = function()
                        self:setMaxSyncDownload()
                    end,
                    align = "left",
            }},
            {{
                    text = _("Set sync folder"),
                    callback = function()
                        self:setSyncDir()
                    end,
                    align = "left",
            }},
            {{
                    text = _("Set file types to sync"),
                    callback = function()
                        self:setSyncFiletypes()
                    end,
                    align = "left",
            }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

function OPDSBrowser:findCurrentServer()
    for _, server in ipairs(self.servers) do
        if server.title == self.root_catalog_title then
            return server
        end
    end
end

function OPDSBrowser:editFilterList(field_name, title, description, hint)
    local current_server = self:findCurrentServer()
    if not current_server then
        UIManager:show(InfoMessage:new{text = _("No catalog selected")})
        return
    end

    local current_value = table.concat(current_server[field_name] or {}, ", ")
    local dialog
    dialog = InputDialog:new{
        title = title,
        description = description,
        input_hint = hint,
        input = current_value,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_text = dialog:getInputText()
                        current_server[field_name] = parseCSVList(input_text)
                        self._manager.updated = true
                        UIManager:close(dialog)
                        if self.paths and #self.paths > 0 and self.paths[#self.paths] then
                            self:updateCatalog(self.paths[#self.paths].url, true)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows facet menu for OPDS catalogs with facets/search support
function OPDSBrowser:showFacetMenu()
    local buttons = {}
    local dialog
    local catalog_url = self.paths[#self.paths].url

    -- Add sub-catalog to bookmarks option first
    table.insert(buttons, {{
        text = "\u{f067} " .. _("Add catalog"),
        callback = function()
            UIManager:close(dialog)
            self:addSubCatalog(catalog_url)
        end,
        align = "left",
    }})
    local server = self.root_catalog_server_idx and self.servers[self.root_catalog_server_idx]

    -- "Load all entries" when there are more pages
    if self.item_table.hrefs and self.item_table.hrefs.next then
        table.insert(buttons, {{
            text = "\u{f03a} " .. _("Load all entries"),
            callback = function()
                UIManager:close(dialog)
                self:loadAllPages()
            end,
            align = "left",
        }})
    end
    -- Persistent per-catalog toggles
    if server then
        table.insert(buttons, {{
            text = (server.load_all and "✓ " or "") .. _("Always load all entries"),
            callback = function()
                UIManager:close(dialog)
                server.load_all = not server.load_all or nil
                self.root_catalog_load_all = server.load_all
                self._manager.updated = true
            end,
            align = "left",
        }})
    end
    -- Sort: one-shot buttons (left) + persistent toggle (right)
    local sort_order = server and server.sort_order
    table.insert(buttons, {
        {
            text = (sort_order == "asc" and "✓ " or "") .. _("Sort A→Z"),
            callback = function()
                UIManager:close(dialog)
                if server then
                    local new_order = sort_order == "asc" and nil or "asc"
                    server.sort_order = new_order
                    self.root_catalog_sort_order = new_order
                    self._manager.updated = true
                end
                table.sort(self.item_table, function(a, b) return a.text < b.text end)
                self:switchItemTable(self.catalog_title, self.item_table, -1)
            end,
        },
        {
            text = (sort_order == "desc" and "✓ " or "") .. _("Sort Z→A"),
            callback = function()
                UIManager:close(dialog)
                if server then
                    local new_order = sort_order == "desc" and nil or "desc"
                    server.sort_order = new_order
                    self.root_catalog_sort_order = new_order
                    self._manager.updated = true
                end
                table.sort(self.item_table, function(a, b) return a.text > b.text end)
                self:switchItemTable(self.catalog_title, self.item_table, -1)
            end,
        },
    })
    table.insert(buttons, {}) -- separator

    -- Add filter settings
    local filter_defs = {
        { field = "excluded_authors",    title = _("Excluded Authors"),    desc = _("Comma-separated list of authors to exclude"),    hint = _("Author One, Author Two") },
        { field = "excluded_categories", title = _("Excluded Categories"), desc = _("Comma-separated list of categories to exclude"), hint = _("Fiction, Non-Fiction") },
        { field = "included_authors",    title = _("Included Authors"),    desc = _("Comma-separated list of authors to include"),    hint = _("Author One, Author Two") },
        { field = "included_categories", title = _("Included Categories"), desc = _("Comma-separated list of categories to include"), hint = _("Fiction, Non-Fiction") },
    }
    for _, def in ipairs(filter_defs) do
        table.insert(buttons, {{
            text = "\u{f0b0} " .. def.title,
            callback = function()
                UIManager:close(dialog)
                self:editFilterList(def.field, def.title, def.desc, def.hint)
            end,
            align = "left",
        }})
    end
    table.insert(buttons, {}) -- separator

    -- Add search option if available
    if self.search_url then
        table.insert(buttons, {{
            text = "\u{f002} " .. _("Search"),
            callback = function()
                UIManager:close(dialog)
                self:searchCatalog(self.search_url)
            end,
            align = "left",
        }})
        table.insert(buttons, {}) -- separator
    end

    -- Add facet groups
    if self.facet_groups then
        for group_name, facets in ffiUtil.orderedPairs(self.facet_groups) do
            table.insert(buttons, {
                { text = "\u{f0b0} " .. group_name, enabled = false, align = "left" }
            })

            for __, link in ipairs(facets) do
                local facet_text = link.title
                if link["thr:count"] then
                    facet_text = T(_("%1 (%2)"), facet_text, link["thr:count"])
                end
                if link["opds:activeFacet"] == "true" then
                    facet_text = "✓ " .. facet_text
                end
                table.insert(buttons, {{
                    text = facet_text,
                    callback = function()
                        UIManager:close(dialog)
                        self:updateCatalog(url.absolute(catalog_url, link.href))
                    end,
                    align = "left",
                }})
            end
            table.insert(buttons, {}) -- separator between groups
        end
    end

    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end


local function buildRootEntry(server)
    local icons = ""
    if server.username then
        icons = "\u{f2c0}"
    end
    if server.sync then
        icons = "\u{f46a} " .. icons
    end
    return {
        text       = server.title,
        mandatory  = icons,
        url        = server.url,
        username   = server.username,
        password   = server.password,
        raw_names  = server.raw_names,
        searchable = server.url and server.url:match("%%s") and true or false,
        sync       = server.sync,
        sync_dir   = server.sync_dir,
        sort_order = server.sort_order,
        load_all   = server.load_all,
        excluded_authors = server.excluded_authors,
        excluded_categories = server.excluded_categories,
        included_authors = server.included_authors,
        included_categories = server.included_categories,
    }
end

-- Builds the root list of catalogs
function OPDSBrowser:genItemTableFromRoot()
    local item_table = {
        {
            text = _("Downloads"),
            mandatory = #self.downloads,
        },
    }
    for _, server in ipairs(self.servers) do
        table.insert(item_table, buildRootEntry(server))
    end
    return item_table
end

-- Shows dialog to edit properties of the new/existing catalog
function OPDSBrowser:addEditCatalog(item)
    local fields = {
        {
            hint = _("Catalog name"),
        },
        {
            hint = _("Catalog URL"),
        },
        {
            hint = _("Username (optional)"),
        },
        {
            hint = _("Password (optional)"),
            text_type = "password",
        },
        {
            hint = _("Excluded Authors (optional)"),
        },
        {
            hint = _("Excluded Categories (optional)"),
        },
        {
            hint = _("Included Authors (optional)"),
        },
        {
            hint = _("Included Categories (optional)"),
        },
    }
    local title
    if item then
        title = _("Edit OPDS catalog")
        fields[1].text = item.text
        fields[2].text = item.url
        fields[3].text = item.username
        fields[4].text = item.password
        fields[5].text = table.concat(item.excluded_authors or {}, ", ")
        fields[6].text = table.concat(item.excluded_categories or {}, ", ")
        fields[7].text = table.concat(item.included_authors or {}, ", ")
        fields[8].text = table.concat(item.included_categories or {}, ", ")
    else
        title = _("Add OPDS catalog")
    end

    local dialog, check_button_raw_names, check_button_sync_catalog, button_sync_dir
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local new_fields = dialog:getFields()
                        new_fields[9] = check_button_raw_names.checked or nil
                        new_fields[10] = check_button_sync_catalog.checked or nil
                        new_fields[11] = button_sync_dir.sync_dir or nil
                        if self:editCatalogFromInput(new_fields, item) then
                            UIManager:close(dialog)
                        end
                    end,
                },
            },
        },
    }

    check_button_raw_names = CheckButton:new{
        text = _("Use server filenames"),
        checked = item and item.raw_names,
        parent = dialog,
    }
    check_button_sync_catalog = CheckButton:new{
        text = _("Sync catalog"),
        checked = item and item.sync,
        parent = dialog,
    }

    -- Add sync directory button
    button_sync_dir = Button:new{
        text = item and item.sync_dir and _("Sync folder: ") .. item.sync_dir or _("Set sync folder"),
        sync_dir = item and item.sync_dir,
        callback = function()
            local force_chooser_dir_for_per_catalog
            if Device:isAndroid() then
                force_chooser_dir_for_per_catalog = Device.home_dir
            end

            -- Use item sync_dir, global sync_dir, or default download dir as initial path.
            local initial_path = item and item.sync_dir or self.settings.sync_dir or self:getDefaultDownloadDir()

            DownloadMgr:new{
                onConfirm = function(inbox)
                    if inbox then -- Check if user selected a directory and not cancelled
                        button_sync_dir.sync_dir = inbox
                        button_sync_dir:setText(_("Sync folder: ") .. inbox)
                        self._manager.updated = true -- Mark manager as updated for settings persistence
                    end
                end,
            }:chooseDir(initial_path or force_chooser_dir_for_per_catalog)
        end,
    }

    dialog:addWidget(check_button_raw_names)
    dialog:addWidget(check_button_sync_catalog)
    dialog:addWidget(button_sync_dir)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows dialog to add a subcatalog to the root list
function OPDSBrowser:addSubCatalog(item_url)
    local dialog
    dialog = InputDialog:new{
        title = _("Add OPDS catalog"),
        input = self.root_catalog_title .. " - " .. self.catalog_title,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = dialog:getInputText()
                        if name ~= "" then
                            UIManager:close(dialog)
                            local fields = {name, item_url,
                                self.root_catalog_username, self.root_catalog_password,
                                nil, nil, nil, nil, -- filter fields (5-8)
                                self.root_catalog_raw_names, -- raw_names (9)
                            }
                            self:editCatalogFromInput(fields, nil, true) -- no init, stay in the subcatalog
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Saves catalog properties from input dialog
function OPDSBrowser:editCatalogFromInput(fields, item, no_refresh)
    local catalog_title = util.trim(fields[1] or "")
    local catalog_url = util.trim(fields[2] or "")
    if catalog_title == "" or catalog_url == "" then
        UIManager:show(InfoMessage:new{
            text = _("Catalog name and URL are required."),
        })
        return false
    end

    local old_server = item and self.servers[item.idx - 1]
    local new_server = {
        title     = catalog_title,
        url       = catalog_url:match("^%a[%w+.-]*://") and catalog_url or "http://" .. catalog_url,
        username  = fields[3] and fields[3] ~= "" and fields[3] or nil,
        password  = fields[4] and fields[4] ~= "" and fields[4] or nil,
        excluded_authors = parseCSVList(fields[5]),
        excluded_categories = parseCSVList(fields[6]),
        included_authors = parseCSVList(fields[7]),
        included_categories = parseCSVList(fields[8]),
        raw_names = fields[9],
        sync      = fields[10],
        sync_dir  = fields[11],
        sort_order = old_server and old_server.sort_order,
        load_all   = old_server and old_server.load_all,
    }

    local new_item = buildRootEntry(new_server)
    local new_idx, itemnumber
    if item then
        new_idx = item.idx
        itemnumber = -1
    else
        new_idx = #self.servers + 2
        itemnumber = new_idx
    end
    self.servers[new_idx - 1] = new_server -- first item is "Downloads"
    self.item_table[new_idx] = new_item
    if not no_refresh then
        self:switchItemTable(nil, self.item_table, itemnumber)
    end
    self._manager.updated = true
    return true
end

-- Deletes catalog from the root list
function OPDSBrowser:deleteCatalog(item)
    table.remove(self.servers, item.idx - 1)
    table.remove(self.item_table, item.idx)
    self:switchItemTable(nil, self.item_table, -1)
    self._manager.updated = true
end

-- Fetches feed from server
function OPDSBrowser:fetchFeed(item_url, headers_only)
    local parsed = url.parse(item_url or "")
    local scheme = parsed and parsed.scheme
    if scheme ~= "http" and scheme ~= "https" then
        if not headers_only then
            UIManager:show(InfoMessage:new {
                text = T(_("Invalid protocol:\n%1"), scheme or _("unknown")),
            })
        end
        logger.warn("OPDSBrowser:fetchFeed: invalid protocol", scheme)
        return nil
    end

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local request = {
        url      = item_url,
        method   = headers_only and "HEAD" or "GET",
        -- Explicitly specify that we don't support compressed content.
        -- Some servers will still break RFC2616 14.3 and send crap instead.
        headers  = {
            ["Accept-Encoding"] = "identity",
        },
        sink     = ltn12.sink.table(sink),
        user     = self.root_catalog_username,
        password = self.root_catalog_password,
    }
    logger.dbg("Request:", socketutil.redact_request(request))
    local ok, code, headers, status = pcall(function()
        return socket.skip(1, http.request(request))
    end)
    socketutil:reset_timeout()
    if not ok then
        logger.warn("OPDSBrowser:fetchFeed: request failed", code)
        status = code
        code, headers = nil, nil
    end

    if headers_only then
        return headers
    end
    if code == 200 then
        local xml = table.concat(sink)
        return xml ~= "" and xml
    end

    local text, icon
    local location = headers and headers.location
    local downgrade_location = redirectDowngradeLocation(item_url, code, location)
    if downgrade_location then
        text = T(_("Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
            BD.url(item_url), BD.url(downgrade_location))
        icon = "notice-warning"
    elseif headers and tonumber(code) == 301 and location then
        text = T(_("The catalog has been permanently moved. Please update catalog URL to '%1'."), BD.url(location))
    else
        local error_message = {
            ["401"] = _("Authentication required for catalog. Please add a username and password."),
            ["403"] = _("Failed to authenticate. Please check your username and password."),
            ["404"] = _("Catalog not found."),
            ["406"] = _("Cannot get catalog. Server refuses to serve uncompressed content."),
        }
        text = code and error_message[tostring(code)] or T(_("Cannot get catalog. Server response status: %1."), status or code)
    end
    UIManager:show(InfoMessage:new{
        text = text,
        icon = icon,
    })
    logger.dbg(string.format("OPDS: Failed to fetch catalog `%s`: %s", redactURLForLog(item_url), text))
end

-- Parses feed to catalog
function OPDSBrowser:parseFeed(item_url)
    local headers = self:fetchFeed(item_url, true)
    local feed_last_modified = headers and headers["last-modified"]
    local feed
    if feed_last_modified then
        local hash = "opds|catalog|" .. item_url .. "|" .. feed_last_modified
        feed = CatalogCache:check(hash)
        if feed then
            logger.dbg("Cache hit for", hash)
        else
            logger.dbg("Cache miss for", hash)
            feed = self:fetchFeed(item_url)
            if feed then
                logger.dbg("Caching", hash)
                CatalogCache:insert(hash, feed)
            end
        end
    else
        feed = self:fetchFeed(item_url)
    end
    if feed then
        return OPDSParser:parse(feed)
    end
end

-- Decodes RFC 2047 MIME encoded-words that some servers wrap filenames in.
-- e.g. =?UTF-8?Q?My=5FBook.epub?= -> "My_Book.epub"
--      =?UTF-8?B?TXkgQm9vay5lcHVi?= -> "My Book.epub"
local function decodeMIMEEncodedWords(str)
    if not str or not str:find("=%?") then return str end
    return (str:gsub("=%?([^?]+)%?([BbQq])%?([^?]*)%?=", function(_, encoding, text)
        if encoding:upper() == "Q" then
            text = text:gsub("_", " ")
            text = text:gsub("=(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
        elseif encoding:upper() == "B" then
            local ok, mime = pcall(require, "mime")
            if ok and mime.unb64 then
                text = mime.unb64(text) or text
            end
        end
        return text
    end))
end

function OPDSBrowser:getServerFileName(item_url, filetype)
    if type(item_url) ~= "string" or item_url == "" then
        return filetype and "download." .. filetype:lower() or "download"
    end

    local headers = self:fetchFeed(item_url, true)
    local filename

    if headers then
        logger.dbg("OPDSBrowser: server file headers", socketutil.redact_headers(headers))
        local disposition = headers["content-disposition"]
        if disposition then
            -- RFC 5987 filename* (preferred per RFC 6266, handles non-ASCII properly)
            local encoded = disposition:match("[Ff]ilename%*=[Uu][Tt][Ff]%-8''([^;%s]+)")
            if encoded then
                filename = url.unescape(encoded)
            end
            if not filename then
                -- Try to get filename inside quotes (can contain spaces)
                filename = disposition:match('filename="([^"]+)"')
                if not filename then
                    -- Fallback: try filename without quotes, until end or semicolon
                    filename = disposition:match('filename=([^;]+)')
                end
                if filename then
                    filename = decodeMIMEEncodedWords(filename)
                end
            end
        end

        -- If not found, try from redirect URL (location)
        if not filename and headers["location"] then
            filename = url.unescape(headers["location"]:gsub("[?#].*", ""):gsub(".*/", ""))
        end
    end

    -- If still no filename, extract from original URL (remove path and query params)
    if not filename then
        filename = url.unescape(item_url:gsub("[?#].*", ""):gsub(".*/", ""))
    end

    if filename and filetype then
        local current_suffix = util.getFileNameSuffix(filename)
        -- Add extension if missing
        if not current_suffix then
            filename = filename .. "." .. filetype:lower()
        end
    end

    return filename
end

-- Generates link to search in catalog
function OPDSBrowser:getSearchTemplate(osd_url)
    -- parse search descriptor
    local ok, search_descriptor = pcall(function()
        return self:parseFeed(osd_url)
    end)
    if not ok then
        logger.info("Cannot get OPDS search descriptor from", redactURLForLog(osd_url), search_descriptor)
        return nil
    end
    if search_descriptor and search_descriptor.OpenSearchDescription and search_descriptor.OpenSearchDescription.Url then
        for _, candidate in ipairs(search_descriptor.OpenSearchDescription.Url) do
            if candidate.type and candidate.template and candidate.type:find(self.search_template_type) then
                return candidate.template:gsub("{searchTerms}", "%%s")
            end
        end
    end
end

-- Generates menu items from the fetched list of catalog entries
function OPDSBrowser:genItemTableFromURL(item_url)
    local ok, catalog = pcall(self.parseFeed, self, item_url)
    if not ok then
        logger.info("Cannot get catalog info from", item_url, catalog)
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot get catalog info from %1"), (item_url and BD.url(item_url) or "nil")),
        })
        catalog = nil
    end
    return self:genItemTableFromCatalog(catalog, item_url)
end

-- Generates catalog item table and processes OPDS facets/search links
function OPDSBrowser:genItemTableFromCatalog(catalog, item_url)
    local item_table = {}
    self.facet_groups = nil -- Reset facets
    self.search_url = nil   -- Reset search URL

    if not catalog then
        return item_table
    end

    local feed = catalog.feed or catalog
    self.facet_groups = {} -- Initialize table to store facet groups

    local function build_href(href)
        if not href then return nil end
        return url.absolute(item_url, href)
    end

    local has_opensearch = false
    local hrefs = {}
    if feed.link then
        for __, link in ipairs(feed.link) do
            if link.type ~= nil then
                if link.type:find(self.catalog_type) then
                    if link.rel and link.href then
                        hrefs[link.rel] = build_href(link.href)
                    end
                end
                if not self.sync then
                    -- OpenSearch
                    if link.type:find(self.search_type) then
                        if link.href then
                            local search_template = self:getSearchTemplate(build_href(link.href))
                            if search_template then
                                self.search_url = build_href(search_template)
                                has_opensearch = true
                            end
                        end
                    end
                    -- Calibre search (also matches the actual template for OpenSearch!)
                    if link.type:find(self.search_template_type) and link.rel and link.rel:find("search") then
                        if link.href and not has_opensearch then
                            self.search_url = build_href(link.href:gsub("{searchTerms}", "%%s"))
                        end
                    end
                    -- Process OPDS facets
                    if link.rel == self.facet_rel then
                        local group_name = link["opds:facetGroup"] or _("Filters")
                        if not self.facet_groups[group_name] then
                            self.facet_groups[group_name] = {}
                        end
                        table.insert(self.facet_groups[group_name], link)
                    end
                end
            end
        end
    end
    item_table.hrefs = hrefs

    for __, entry in ipairs(feed.entry or {}) do
        local item = {}
        item.acquisitions = {}
        if entry.link then
            for ___, link in ipairs(entry.link) do
                local link_href = build_href(link.href)
                if link.type and link.type:find(self.catalog_type)
                        and (not link.rel
                             or link.rel == "subsection"
                             or link.rel == "http://opds-spec.org/subsection"
                             or link.rel == "http://opds-spec.org/sort/popular"
                             or link.rel == "http://opds-spec.org/sort/new") then
                    item.url = link_href
                end
                -- Some catalogs do not use the rel attribute to denote
                -- a publication. Arxiv uses title. Specifically, it uses
                -- a title attribute that contains pdf. (title="pdf")
                if link.rel or link.title then
                    if link.rel == self.borrow_rel then
                        table.insert(item.acquisitions, {
                            type = "borrow",
                        })
                    elseif link.href and link.rel and link.rel:match(self.acquisition_rel) then
                        table.insert(item.acquisitions, {
                            type  = link.type,
                            href  = link_href,
                            title = link.title,
                        })
                    elseif link.href and link.rel == self.stream_rel then
                        -- https://vaemendis.net/opds-pse/
                        -- «count» MUST provide the number of pages of the document
                        -- namespace may be not "pse"
                        local count, last_read
                        for k, v in pairs(link) do
                            if k:sub(-6) == ":count" then
                                count = tonumber(v)
                            elseif k:sub(-9) == ":lastRead" then
                                last_read = tonumber(v)
                            end
                        end
                        if count then
                            table.insert(item.acquisitions, {
                                type  = link.type,
                                href  = link_href,
                                title = link.title,
                                count = count,
                                last_read = last_read and last_read > 0 and last_read or nil
                            })
                        end
                    elseif self.thumbnail_rel[link.rel] then
                        item.thumbnail = link_href
                    elseif self.image_rel[link.rel] then
                        item.image = link_href
                    elseif link.href and link.rel ~= "alternate" and DocumentRegistry:hasProvider(nil, link.type) then
                        table.insert(item.acquisitions, {
                            type  = link.type,
                            href  = link_href,
                            title = link.title,
                        })
                    end
                    -- This statement grabs the catalog items that are
                    -- indicated by title="pdf" or whose type is
                    -- "application/pdf"
                    if link.href and (link.title == "pdf" or link.type == "application/pdf")
                        and link.rel ~= "subsection" then
                        -- Check for the presence of the pdf suffix and add it
                        -- if it's missing.
                        local original_href = link.href
                        local parsed = url.parse(original_href)
                        if not parsed then parsed = { path = original_href } end
                        local path = parsed.path or ""
                        -- Calibre web OPDS download links end with "/<filetype>/"
                        if not util.stringEndsWith(path, "/pdf/") then
                            local appended = false
                            if util.getFileNameSuffix(path) ~= "pdf" then
                                if path == "" then
                                    path = ".pdf"
                                else
                                    path = path .. ".pdf"
                                end
                                appended = true
                            end
                            if appended then
                                parsed.path = path
                                local new_href = url.build(parsed)
                                table.insert(item.acquisitions, {
                                    type = link.title,
                                    href = build_href(new_href),
                                })
                            end
                        end
                    end
                end
            end
        end
        local title = _("Unknown")
        if type(entry.title) == "string" then
            title = entry.title
        elseif type(entry.title) == "table" then
            if type(entry.title.type) == "string" and entry.title.div ~= "" then
                title = entry.title.div
            end
        end
        item.text = title
        local author = _("Unknown Author")
        if type(entry.author) == "table" and entry.author.name then
            author = entry.author.name
            if type(author) == "table" then
                if #author > 0 then
                    author = table.concat(author, ", ")
                else
                    -- we may get an empty table on https://gallica.bnf.fr/opds
                    author = nil
                end
            end
            if author then
                item.text = title .. " - " .. author
            end
        end
        item.title = title
        item.author = author
        item.content = entry.content or entry.summary

        local current_server = self.root_catalog_server_idx and self.servers[self.root_catalog_server_idx]
        if current_server and current_server.title ~= self.root_catalog_title then
            current_server = nil
        end
        if not current_server then
            for _, server in ipairs(self.servers) do
                if server.title == self.root_catalog_title then
                    current_server = server
                    break
                end
            end
        end

        if current_server then
            -- Include filters are applied first. If set, at least one include filter must match.
            if listHasEntries(current_server.included_authors)
                and not listContainsText(current_server.included_authors, author) then
                goto continue_entry
            end
            if listHasEntries(current_server.included_categories)
                and not listContainsCategory(current_server.included_categories, entry) then
                goto continue_entry
            end

            -- Exclude filters then remove matching entries from the included set.
            if listContainsText(current_server.excluded_authors, author)
                or listContainsCategory(current_server.excluded_categories, entry) then
                goto continue_entry
            end
        end

        table.insert(item_table, item)
        ::continue_entry::
    end

    if next(self.facet_groups) == nil then self.facet_groups = nil end -- Clear if empty

    return item_table
end

-- Requests and shows updated list of catalog entries
function OPDSBrowser:updateCatalog(item_url, paths_updated)
    local menu_table = self:genItemTableFromURL(item_url)
    if #menu_table > 0 or self.facet_groups or self.search_url then
        if not paths_updated then
            table.insert(self.paths, {
                url   = item_url,
                title = self.catalog_title,
            })
        end
        self:switchItemTable(self.catalog_title, menu_table)

        self:setTitleBarLeftIcon("appbar.menu")
        self.onLeftButtonTap = function()
            self:showFacetMenu()
        end

        if self.root_catalog_load_all and self.item_table.hrefs and self.item_table.hrefs.next then
            self:loadAllPages()
        else
            if self.page_num <= 1 then
                self:onNextPage(true)
            end
            if self.root_catalog_sort_order then
                self:applySortOrder()
                self:switchItemTable(self.catalog_title, self.item_table, -1)
            end
        end
    end
end

-- Requests and adds more catalog entries to fill out the page
function OPDSBrowser:appendCatalog(item_url)
    local menu_table = self:genItemTableFromURL(item_url)
    if #menu_table > 0 then
        for __, item in ipairs(menu_table) do
            table.insert(self.item_table, item)
        end
        self.item_table.hrefs = menu_table.hrefs
        self:switchItemTable(self.catalog_title, self.item_table, -1)
        return true
    end
end

-- Fetches all remaining pages of the current catalog so the full list is available
function OPDSBrowser:loadAllPages()
    local hrefs = self.item_table.hrefs
    if not hrefs or not hrefs.next then
        UIManager:show(InfoMessage:new{
            text = _("All entries are already loaded."),
        })
        return
    end

    local saved_facets = self.facet_groups
    local saved_search = self.search_url

    local info = InfoMessage:new{
        text = T(_("Loading entries: %1 so far…"), #self.item_table),
    }
    UIManager:show(info)
    UIManager:forceRePaint()

    while true do
        hrefs = self.item_table.hrefs
        if not hrefs or not hrefs.next then break end

        local menu_table = self:genItemTableFromURL(hrefs.next)
        if #menu_table == 0 then break end

        for __, item in ipairs(menu_table) do
            table.insert(self.item_table, item)
        end
        self.item_table.hrefs = menu_table.hrefs

        UIManager:close(info)
        info = InfoMessage:new{
            text = T(_("Loading entries: %1 so far…"), #self.item_table),
        }
        UIManager:show(info)
        UIManager:forceRePaint()
    end

    UIManager:close(info)

    self.facet_groups = saved_facets
    self.search_url = saved_search

    self:applySortOrder()
    self:switchItemTable(self.catalog_title, self.item_table, -1)
    UIManager:show(InfoMessage:new{
        text = T(_("Loaded %1 entries."), #self.item_table),
        timeout = 2,
    })
end

-- Sorts the current item_table according to the configured sort_order
function OPDSBrowser:applySortOrder()
    local order = self.root_catalog_sort_order
    if not order then return end
    if order == "asc" then
        table.sort(self.item_table, function(a, b) return a.text < b.text end)
    elseif order == "desc" then
        table.sort(self.item_table, function(a, b) return a.text > b.text end)
    end
end

-- Shows dialog to search in catalog
function OPDSBrowser:searchCatalog(item_url)
    local dialog
    dialog = InputDialog:new{
        title = _("Search OPDS catalog"),
        -- @translators: This is an input hint for something to search for in an OPDS catalog, namely a famous author everyone knows. It probably doesn't need to be localized, but this is just here in case another name or book title would be more appropriate outside of a European context.
        input_hint = _("Alexandre Dumas"),
        description = _("%s in url will be replaced by your input"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        self.catalog_title = _("Search results")
                        local search_str = util.urlEncode(dialog:getInputText())
                        -- Use function replacement to avoid % being treated as capture refs
                        item_url = item_url:gsub("%%s", function() return search_str end)
                        self:updateCatalog(item_url)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Shows dialog to download / stream a book
function OPDSBrowser:showDownloads(item)
    local acquisitions = item.acquisitions
    local filename, filename_orig = self:getFileName(item)

    local function createTitle(path, file) -- title for ButtonDialog
        return T(_("Download folder:\n%1\n\nDownload filename:\n%2\n\nDownload file type:"),
            path and BD.dirpath(path) or _("Not set"), file or _("<server filename>"))
    end

    local buttons = {} -- buttons for ButtonDialog
    local stream_buttons -- page stream buttons
    local download_buttons = {} -- file type download buttons
    for _, acquisition in ipairs(acquisitions) do -- filter out unsupported file types
        if acquisition.count then
            stream_buttons = {
                {
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = "\u{23EE} " .. _("Page stream"), -- prepend BLACK LEFT-POINTING DOUBLE TRIANGLE WITH BAR
                        callback = function()
                            OPDSPSE:streamPages(acquisition.href, acquisition.count, false, self.root_catalog_username, self.root_catalog_password)
                            UIManager:close(self.download_dialog)
                        end,
                    },
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = _("Stream from page") .. " \u{23E9}", -- append BLACK RIGHT-POINTING DOUBLE TRIANGLE
                        callback = function()
                            OPDSPSE:streamPages(acquisition.href, acquisition.count, true, self.root_catalog_username, self.root_catalog_password)
                            UIManager:close(self.download_dialog)
                        end,
                    },
                },
            }

            if acquisition.last_read then
                table.insert(stream_buttons, {
                    {
                        -- @translators "Stream" here refers to being able to read documents from an OPDS server without downloading them completely, on a page by page basis.
                        text = "\u{25B6} " .. _("Resume stream from page") .. " " .. acquisition.last_read, -- prepend BLACK RIGHT-POINTING TRIANGLE
                        callback = function()
                            OPDSPSE:streamPages(acquisition.href, acquisition.count, false, self.root_catalog_username, self.root_catalog_password, acquisition.last_read)
                            UIManager:close(self.download_dialog)
                        end,
                    },
                })
            end
        elseif acquisition.type == "borrow" then
            table.insert(download_buttons, {
                text = _("Borrow"),
                enabled = false,
            })
        else
            local filetype = self.getFiletype(acquisition)
            if filetype then -- supported file type
                local text = url.unescape(acquisition.title or string.upper(filetype))
                table.insert(download_buttons, {
                    text = text .. "\u{2B07}", -- append DOWNWARDS BLACK ARROW
                    callback = function()
                        UIManager:close(self.download_dialog)
                        local local_path = self:getLocalDownloadPath(nil, filename, filetype, acquisition.href)
                        self:checkDownloadFile(local_path, acquisition.href, self.root_catalog_username, self.root_catalog_password, self.file_downloaded_callback)
                    end,
                    hold_callback = function()
                        UIManager:close(self.download_dialog)
                        local local_path = self:getLocalDownloadPath(nil, filename, filetype, acquisition.href)
                        if local_path then
                            table.insert(self.downloads, {
                                file     = local_path,
                                url      = acquisition.href,
                                info     = type(item.content) == "string" and util.htmlToPlainTextIfHtml(item.content) or "",
                                catalog  = self.root_catalog_title,
                                username = self.root_catalog_username,
                                password = self.root_catalog_password,
                            })
                            self._manager.updated = true
                            Notification:notify(_("Book added to download list"), Notification.SOURCE_OTHER)
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Please choose a download folder first."),
                            })
                        end
                    end,
                })
            end
        end
    end

    local buttons_nb = #download_buttons
    if buttons_nb > 0 then
        if buttons_nb == 1 then -- one wide button
            table.insert(buttons, download_buttons)
        else
            if buttons_nb % 2 == 1 then -- we need even number of buttons
                table.insert(download_buttons, {text = ""})
            end
            for i = 1, buttons_nb, 2 do -- two buttons in a row
                table.insert(buttons, {download_buttons[i], download_buttons[i+1]})
            end
        end
        table.insert(buttons, {}) -- separator
    end
    if stream_buttons then
        for _, button_list in ipairs(stream_buttons) do
            table.insert(buttons, button_list)
        end
        table.insert(buttons, {}) -- separator
    end
    table.insert(buttons, { -- action buttons
        {
            text = _("Choose folder"),
            callback = function()
                require("ui/downloadmgr"):new{
                    onConfirm = function(path)
                        logger.dbg("Download folder set to", path)
                        G_reader_settings:saveSetting("download_dir", path)
                        self.download_dialog:setTitle(createTitle(path, filename))
                    end,
                }:chooseDir(self:getCurrentDownloadDir())
            end,
        },
        {
            text = _("Change filename"),
            callback = function()
                local dialog
                dialog = InputDialog:new{
                    title = _("Enter filename"),
                    input = filename or filename_orig,
                    input_hint = filename_orig,
                    buttons = {
                        {
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function()
                                    UIManager:close(dialog)
                                end,
                            },
                            {
                                text = _("Set filename"),
                                is_enter_default = true,
                                callback = function()
                                    filename = dialog:getInputValue()
                                    if filename == "" then
                                        filename = filename_orig
                                    end
                                    UIManager:close(dialog)
                                    self.download_dialog:setTitle(createTitle(self:getCurrentDownloadDir(), filename))
                                end,
                            },
                        }
                    },
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
    })
    local cover_link = item.image or item.thumbnail
    table.insert(buttons, {
        {
            text = _("Book cover"),
            enabled = cover_link and true or false,
            callback = function()
                OPDSPSE:streamPages(cover_link, 1, false, self.root_catalog_username, self.root_catalog_password)
            end,
        },
        {
            text = _("Book information"),
            enabled = type(item.content) == "string",
            callback = function()
                UIManager:show(TextViewer:new{
                    title = item.text,
                    title_multilines = true,
                    text = util.htmlToPlainTextIfHtml(item.content),
                    text_type = "book_info",
                })
            end,
        },
    })

    self.download_dialog = ButtonDialog:new{
        title = createTitle(self:getCurrentDownloadDir(), filename),
        buttons = buttons,
    }
    UIManager:show(self.download_dialog)
end

-- Helper function to get the filetype from an acquisitions table
function OPDSBrowser.getFiletype(link)
    local href = link.href or ""
    local parsed = url.parse(href)
    local path = (parsed and parsed.path or href):gsub("[?#].*", "")
    local filetype = path ~= "" and util.getFileNameSuffix(path) or nil
    if filetype then
        filetype = filetype:lower()
        if not DocumentRegistry:hasProvider("dummy." .. filetype) then
            filetype = nil
        end
    end
    if not filetype and DocumentRegistry:hasProvider(nil, link.type) then
        filetype = DocumentRegistry:mimeToExt(link.type)
        filetype = filetype and filetype:lower()
    end
    return filetype
end

function OPDSBrowser:getDefaultDownloadDir()
    local dir = G_reader_settings:readSetting("download_dir") or G_reader_settings:readSetting("lastdir")
    return dir ~= "" and dir or nil
end

-- Returns user selected or last opened folder
function OPDSBrowser:getCurrentDownloadDir(server)
    if self.sync then
        if server and server.sync_dir and server.sync_dir ~= "" then
            return server.sync_dir
        end
        if self.settings.sync_dir and self.settings.sync_dir ~= "" then
            return self.settings.sync_dir
        end
        return self:getDefaultDownloadDir()
    end
    return self:getDefaultDownloadDir()
end

function OPDSBrowser:getLocalDownloadPath(server, filename, filetype, remote_url)
    local download_dir = self:getCurrentDownloadDir(server)
    if not download_dir or download_dir == "" or not filetype or filetype == "" then
        logger.warn("OPDSBrowser:getLocalDownloadPath: missing download directory or filetype")
        return nil
    end
    filename = filename and filename .. "." .. filetype:lower() or self:getServerFileName(remote_url, filetype)
    if not filename or filename == "" then
        filename = "download." .. filetype:lower()
    end
    filename = util.getSafeFilename(filename, download_dir)
    filename = (download_dir ~= "/" and download_dir or "") .. '/' .. filename
    return util.fixUtf8(filename, "_")
end

-- Downloads a book (with "File already exists" dialog)
function OPDSBrowser:checkDownloadFile(local_path, remote_url, username, password, caller_callback)
    if not local_path then
        UIManager:show(InfoMessage:new{
            text = _("Please choose a download folder first."),
        })
        return
    end

    local function download()
        UIManager:scheduleIn(1, function()
            self:downloadFile(local_path, remote_url, username, password, caller_callback)
        end)
        UIManager:show(InfoMessage:new{
            text = _("Downloading…"),
            timeout = 1,
        })
    end
    if lfs.attributes(local_path) then
        UIManager:show(ConfirmBox:new{
            text = T(_("The file %1 already exists. Do you want to overwrite it?"), BD.filepath(local_path)),
            ok_text = _("Overwrite"),
            ok_callback = function()
                download()
            end,
        })
    else
        download()
    end
end

function OPDSBrowser:downloadFile(local_path, remote_url, username, password, caller_callback)
    if not local_path or local_path == "" then
        UIManager:show(InfoMessage:new{
            text = _("Please choose a download folder first."),
        })
        return false
    end

    local parsed = url.parse(remote_url or "")
    local scheme = parsed and parsed.scheme
    if scheme ~= "http" and scheme ~= "https" then
        UIManager:show(InfoMessage:new {
            text = T(_("Invalid protocol:\n%1"), scheme or _("unknown")),
        })
        return false
    end

    local temp_path = local_path .. ".download"
    local download_dir = util.splitFilePathName(local_path)
    if download_dir and download_dir ~= "" then
        util.makePath(download_dir)
    end

    local file, open_err = io.open(temp_path, "wb")
    if not file then
        UIManager:show(InfoMessage:new {
            text = T(_("Could not save file to:\n%1\n%2"), BD.filepath(local_path), open_err or "open failed"),
        })
        return false
    end

    logger.dbg("Downloading file", local_path, "from", redactURLForLog(remote_url))
    local code, headers, status
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local ok, request_code, request_headers, request_status = pcall(function()
        return socket.skip(1, http.request {
            url      = remote_url,
            headers  = {
                ["Accept-Encoding"] = "identity",
            },
            sink     = ltn12.sink.file(file),
            user     = username,
            password = password,
        })
    end)
    socketutil:reset_timeout()
    if ok then
        code, headers, status = request_code, request_headers, request_status
    else
        status = request_code
        logger.warn("OPDSBrowser:downloadFile: request failed", status)
        pcall(function() file:close() end)
    end

    if code == 200 then
        local renamed, rename_err = os.rename(temp_path, local_path)
        if not renamed then
            util.removeFile(temp_path)
            UIManager:show(InfoMessage:new {
                text = T(_("Could not save file to:\n%1\n%2"), BD.filepath(local_path), rename_err or "rename failed"),
            })
            return false
        end
        logger.dbg("File downloaded to", local_path)
        if caller_callback then
            caller_callback(local_path)
        end
        return true
    end

    util.removeFile(temp_path)
    local downgrade_location = redirectDowngradeLocation(remote_url, code, headers and headers.location)
    if downgrade_location then
        UIManager:show(InfoMessage:new{
            text = T(_("Insecure HTTPS → HTTP downgrade attempted by redirect from:\n\n'%1'\n\nto\n\n'%2'.\n\nPlease inform the server administrator that many clients disallow this because it could be a downgrade attack."),
                BD.url(remote_url), BD.url(downgrade_location)),
            icon = "notice-warning",
        })
    else
        logger.dbg("OPDSBrowser:downloadFile: Request failed:", status or code)
        logger.dbg("OPDSBrowser:downloadFile: Response headers:", headers and socketutil.redact_headers(headers) or nil)
        UIManager:show(InfoMessage:new {
            text = T(_("Could not save file to:\n%1\n%2"),
                BD.filepath(local_path),
                status or code or "network unreachable"),
        })
    end
    return false
end

-- Menu action on item tap (Download a book / Show subcatalog / Search in catalog)
function OPDSBrowser:onMenuSelect(item)
    if item.acquisitions and item.acquisitions[1] then -- book
        logger.dbg("Downloads available:", item)
        self:showDownloads(item)
    else -- catalog or Search item
        if #self.paths == 0 then -- root list
            if item.idx == 1 then
                if #self.downloads > 0 then
                    self:showDownloadList()
                end
                return true
            end
            self.root_catalog_title      = item.text
            self.root_catalog_username   = item.username
            self.root_catalog_password   = item.password
            self.root_catalog_raw_names  = item.raw_names
            self.root_catalog_sort_order = item.sort_order
            self.root_catalog_load_all   = item.load_all
            self.root_catalog_server_idx = item.idx - 1
        end
        local connect_callback
        if item.searchable then
            connect_callback = function()
                self:searchCatalog(item.url)
            end
        else
            self.catalog_title = item.text or self.catalog_title or self.root_catalog_title
            connect_callback = function()
                self:updateCatalog(item.url)
            end
        end
        NetworkMgr:runWhenConnected(connect_callback)
    end
    return true
end

-- Menu action on item long-press (dialog Edit / Delete catalog)
function OPDSBrowser:onMenuHold(item)
    if #self.paths > 0 or item.idx == 1 then return true end -- not root list or Downloads item
    local dialog
    dialog = ButtonDialog:new{
        title = item.text,
        title_align = "center",
        buttons = {
            {
                {
                    text = _("Force sync"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self.sync_force = true
                            self:checkSyncDownload(item.idx)
                        end)
                    end,
                },
                {
                    text = _("Sync"),
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:runWhenConnected(function()
                            self.sync_force = false
                            self:checkSyncDownload(item.idx)
                        end)
                    end,
                },
            },
            {},
            {
                {
                    text = _("Delete"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("Delete OPDS catalog?"),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                UIManager:close(dialog)
                                self:deleteCatalog(item)
                            end,
                        })
                    end,
                },
                {
                    text = _("Edit"),
                    callback = function()
                        UIManager:close(dialog)
                        self:addEditCatalog(item)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- Menu action on return-arrow tap (go to one-level upper catalog)
function OPDSBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        -- return to last path
        self.catalog_title = path.title
        self:updateCatalog(path.url, true)
    else
        -- return to root path, we simply reinit opdsbrowser
        self:init()
    end
    return true
end

-- Menu action on return-arrow long-press (return to root path)
function OPDSBrowser:onHoldReturn()
    self:init()
    return true
end

-- Menu action on next-page chevron tap (request and show more catalog entries)
function OPDSBrowser:onNextPage(fill_only)
    -- self.page_num comes from menu.lua
    local page_num = self.page_num
    -- fetch more entries until we fill out one page or reach the end
    while page_num == self.page_num do
        local hrefs = self.item_table.hrefs
        if hrefs and hrefs.next then
            if not self:appendCatalog(hrefs.next) then
                break  -- reach end of paging
            end
        else
            break
        end
    end
    if not fill_only then
        -- We also *do* want to paginate, so call the base class.
        Menu.onNextPage(self)
    end
    return true
end

function OPDSBrowser:showDownloadList()
    self.download_list = Menu:new{
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        onMenuSelect = self.showDownloadListItemDialog,
        _manager = self,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = self.showDownloadListMenu
    }
    self.download_list.close_callback = function()
        UIManager:close(self.download_list)
        self.download_list = nil
        if self.download_list_updated then
            self.download_list_updated = nil
            self.item_table[1].mandatory = #self.downloads
            self:updateItems(1, true)
        end
    end
    self:updateDownloadListItemTable()
    UIManager:show(self.download_list)
end

function OPDSBrowser:showDownloadListMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {{
                    text = _("Download all"),
                    callback = function()
                        UIManager:close(dialog)
                        self._manager:confirmDownloadDownloadList()
                    end,
                    align = "left",
            }},
            {{
                    text = _("Remove all"),
                    callback = function()
                        UIManager:close(dialog)
                        self._manager:confirmClearDownloadList()
                    end,
                    align = "left",
            }},
        },
        shrink_unneeded_width = true,
        anchor = function()
            return self.title_bar.left_button.image.dimen
        end,
    }
    UIManager:show(dialog)
end

function OPDSBrowser:updateDownloadListItemTable(item_table)
    if item_table == nil then
        item_table = {}
        for i, item in ipairs(self.downloads) do
            item_table[i] = {
                text      = item.file:gsub(".*/", ""),
                mandatory = item.catalog,
            }
        end
    end
    local title = T(_("Downloads (%1)"), #item_table)
    self.download_list:switchItemTable(title, item_table)
end

function OPDSBrowser:confirmDownloadDownloadList()
    UIManager:show(ConfirmBox:new{
        text = _("Download all books?\nExisting files will be overwritten."),
        ok_text = _("Download"),
        ok_callback = function()
            NetworkMgr:runWhenConnected(function()
                Trapper:wrap(function()
                    self:downloadDownloadList()
                end)
            end)
        end,
    })
end

function OPDSBrowser:confirmClearDownloadList()
    UIManager:show(ConfirmBox:new{
        text = _("Remove all downloads?"),
        ok_text = _("Remove"),
        ok_callback = function()
            for i in ipairs(self.downloads) do
                self.downloads[i] = nil
            end
            self.download_list_updated = true
            self._manager.updated = true
            self.download_list:close_callback()
        end,
    })
end

function OPDSBrowser:showDownloadListItemDialog(item)
    local dl_item = self._manager.downloads[item.idx]
    local textviewer
    local function remove_item()
        textviewer:onClose()
        table.remove(self._manager.downloads, item.idx)
        table.remove(self.item_table, item.idx)
        self._manager:updateDownloadListItemTable(self.item_table)
        self._manager.download_list_updated = true
        self._manager._manager.updated = true
    end
    local buttons_table = {
        {
            {
                text = _("Remove"),
                callback = function()
                    remove_item()
                end,
            },
            {
                text = _("Download"),
                callback = function()
                    local function file_downloaded_callback(local_path)
                        remove_item()
                        self._manager.file_downloaded_callback(local_path)
                    end
                    NetworkMgr:runWhenConnected(function()
                        self._manager:checkDownloadFile(dl_item.file, dl_item.url, dl_item.username, dl_item.password, file_downloaded_callback)
                    end)
                end,
            },
        },
        {}, -- separator
        {
            {
                text = _("Remove all"),
                callback = function()
                    textviewer:onClose()
                    self._manager:confirmClearDownloadList()
                end,
            },
            {
                text = _("Download all"),
                callback = function()
                    textviewer:onClose()
                    self._manager:confirmDownloadDownloadList()
                end,
            },
        },
    }
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local text = table.concat({
        TextBoxWidget.PTF_HEADER,
        TextBoxWidget.PTF_BOLD_START, _("Folder"), TextBoxWidget.PTF_BOLD_END, "\n",
        util.splitFilePathName(dl_item.file), "\n", "\n",
        TextBoxWidget.PTF_BOLD_START, _("File"), TextBoxWidget.PTF_BOLD_END, "\n",
        item.text, "\n", "\n",
        TextBoxWidget.PTF_BOLD_START, _("Description"), TextBoxWidget.PTF_BOLD_END, "\n",
        dl_item.info,
    })
    textviewer = TextViewer:new{
        title = dl_item.catalog,
        text = text,
        text_type = "book_info",
        buttons_table = buttons_table,
    }
    UIManager:show(textviewer)
    return true
end

-- Download whole download list
function OPDSBrowser:downloadDownloadList()
    local total = #self.downloads
    local dl_count = 0
    local downloaded_files = {}

    for idx, item in ipairs(self.downloads) do
        local info = InfoMessage:new{
            text = T(_("Downloading %1 of %2…\n(tap to stop)"), idx, total)
        }
        UIManager:show(info)
        UIManager:forceRePaint()

        local completed, success = Trapper:dismissableRunInSubprocess(function()
            return self:downloadFile(item.file, item.url, item.username, item.password)
        end, info)

        if completed then
            UIManager:close(info)
            if success then
                dl_count = dl_count + 1
                downloaded_files[item.file] = true
            else
                local temp_path = item.file .. ".download"
                if lfs.attributes(temp_path) then os.remove(temp_path) end
            end
        else
            local temp_path = item.file .. ".download"
            if lfs.attributes(temp_path) then os.remove(temp_path) end

            local stop = Trapper:confirm(
                T(_("Downloaded %1 of %2.\nStop downloading?"), dl_count, total),
                _("Continue"), _("Stop"))
            if stop then break end
        end
    end

    -- Remove successfully downloaded items
    for i = #self.downloads, 1, -1 do
        if downloaded_files[self.downloads[i].file] then
            table.remove(self.downloads, i)
        end
    end

    if dl_count > 0 then
        self:updateDownloadListItemTable()
        self.download_list_updated = true
        self._manager.updated = true
        UIManager:show(Notification:new{ text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count) })
    end
end

function OPDSBrowser:setMaxSyncDownload()
    local current_max_dl = tonumber(self.settings.sync_max_dl) or 50
    local spin = SpinWidget:new{
        title_text = _("Set maximum sync size"),
        info_text = _("Set the max number of books to download at a time"),
        value = current_max_dl,
        value_min = 0,
        value_max = 1000,
        value_step = 10,
        value_hold_step = 50,
        default_value = 50,
        wrap = true,
        ok_text = _("Save"),
        callback = function(spin)
            self.settings.sync_max_dl = spin.value
            self._manager.updated = true
        end,
    }
    UIManager:show(spin)
end

function OPDSBrowser:setSyncDir()
    local force_chooser_dir
    if Device:isAndroid() then
        force_chooser_dir = Device.home_dir
    end

    require("ui/downloadmgr"):new{
        onConfirm = function(inbox)
            logger.info("set opds sync folder", inbox)
            self.settings.sync_dir = inbox
            self._manager.updated = true
        end,
    }:chooseDir(force_chooser_dir)
end

-- Set string for desired filetypes
function OPDSBrowser:setSyncFiletypes(filetype_list)
    local input = self.settings.filetypes
    local dialog
    dialog = InputDialog:new{
        title = _("File types to sync"),
        description = _("A comma separated list of desired filetypes"),
        input_hint = _("epub, mobi"),
        input = input,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local str = dialog:getInputText()
                        self.settings.filetypes = str ~= "" and str or nil
                        self._manager.updated = true
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Helper function to get filename and set nil if using raw names
function OPDSBrowser:getFileName(item)
    local filename = item.title
    if item.author then
        filename = item.author .. " - " .. filename
    end
    local filename_orig = filename
    if self.root_catalog_raw_names then
        filename = nil
    end
    return filename and util.replaceAllInvalidChars(filename) or nil,
        filename_orig and util.replaceAllInvalidChars(filename_orig) or nil
end

function OPDSBrowser:updateFieldInCatalog(item, name, value)
    item[name] = value
    self._manager.updated = true
end

function OPDSBrowser:checkSyncDownload(idx, auto_sync, completion_callback)
    logger.dbg("OPDS: checkSyncDownload called, global sync_dir =", self.settings.sync_dir)

    local function get_effective_sync_dir(server)
        if server and server.sync_dir and server.sync_dir ~= "" then
            return server.sync_dir
        end
        if self.settings.sync_dir and self.settings.sync_dir ~= "" then
            return self.settings.sync_dir
        end
        return self:getDefaultDownloadDir()
    end

    local has_sync_target = false
    if idx then
        has_sync_target = get_effective_sync_dir(self.servers[idx - 1]) and true or false
    else
        for _, item in ipairs(self.servers) do
            if item.sync and get_effective_sync_dir(item) then
                has_sync_target = true
                break
            end
        end
    end

    if not has_sync_target then
        logger.dbg("OPDS: No sync download directory configured")
        if not auto_sync then
            UIManager:show(InfoMessage:new{
                text = _("Please choose a folder for sync downloads first"),
            })
        end
        if completion_callback then completion_callback() end
        return
    end

    logger.dbg("OPDS: Starting sync process")
    self.sync = true
    self.sync_server_list = {}
    local info
    if not auto_sync then
        info = InfoMessage:new{
            text = _("Synchronizing lists…"),
        }
        UIManager:show(info)
        UIManager:forceRePaint()
    end

    local fill_ok, fill_err = pcall(function()
        if idx then
            local server = self.servers[idx - 1] -- First item is "Downloads"
            if server then
                self:fillPendingSyncs(server)
            end
        else
            for _, item in ipairs(self.servers) do
                if item.sync then
                    if get_effective_sync_dir(item) then
                        self:fillPendingSyncs(item)
                    else
                        logger.warn("OPDS: Skipping synced catalog without download directory", item.title)
                    end
                end
            end
        end
    end)

    if not auto_sync and info then
        UIManager:close(info)
    end
    if not fill_ok then
        self.sync = false
        logger.err("OPDS: Failed to build sync list:", fill_err)
        if not auto_sync then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not synchronize OPDS catalog:\n%1"), fill_err),
            })
        end
        if completion_callback then completion_callback() end
        return
    end

    if #self.pending_syncs > 0 then
        logger.dbg("OPDS: Found", #self.pending_syncs, "items to download")
        Trapper:wrap(function()
            local success, err = pcall(function()
                self:downloadPendingSyncs(auto_sync)
            end)
            if not success then
                logger.err("OPDS: Download failed:", err)
            end
            self.settings.last_sync_time = os.time()
            self._manager.updated = true
            self._manager:saveSettings()
            self.sync = false
            logger.dbg("OPDS: Sync completed with downloads")
            if completion_callback then completion_callback() end
        end)
    else
        if not auto_sync then
            UIManager:show(InfoMessage:new{
                text = _("Up to date!"),
            })
        end
        self.settings.last_sync_time = os.time()
        self._manager.updated = true
        self._manager:saveSettings()
        self.sync = false
        logger.dbg("OPDS: Sync complete - up to date")
        if completion_callback then completion_callback() end
    end
end

-- Add entries to self.pending_syncs
function OPDSBrowser:fillPendingSyncs(server)
    if not server then return end

    self.root_catalog_password  = server.password
    self.root_catalog_raw_names = server.raw_names
    self.root_catalog_username  = server.username
    self.root_catalog_title     = server.title
    self.root_catalog_server_idx = nil
    for idx, item in ipairs(self.servers) do
        if item == server then
            self.root_catalog_server_idx = idx
            break
        end
    end
    self.sync_server            = server
    self.sync_server_list       = self.sync_server_list or {}
    self.sync_max_dl            = tonumber(self.settings.sync_max_dl) or 50

    -- Build a catalog+URL→index map for deduplication and path updates.
    local function pending_key(catalog, item_url)
        return tostring(catalog or "") .. "\0" .. tostring(item_url or "")
    end
    local pending_urls = {}
    for i, item in ipairs(self.pending_syncs) do
        pending_urls[pending_key(item.catalog, item.url)] = i
    end

    local file_list
    local file_str = self.settings.filetypes
    local new_last_download = nil
    local dl_count = 1
    if file_str then
        file_list = {}
        for filetype in util.gsplit(file_str, ",") do
            local trimmed = util.trim(filetype):lower()
            if trimmed ~= "" then
                file_list[trimmed] = true
            end
        end
    end
    local sync_list = self:getSyncDownloadList()
    if sync_list then
        for _, entry in ipairs(sync_list) do
            -- for project gutenberg
            local sub_table = {}
            local item
            if entry.url then
                sub_table = self:getSyncDownloadList(entry.url)
            end
            if #sub_table > 0 then
                -- The first element seems to be most compatible. Second element has most options.
                item = sub_table[2] or sub_table[1]
            else
                item = entry
            end
            for _, link in ipairs(item.acquisitions or {}) do
                local filetype = link.href and self.getFiletype(link)
                if filetype then
                    if not file_str or file_list and file_list[filetype] then
                        local filename = self:getFileName(entry)
                        local download_path = self:getLocalDownloadPath(server, filename, filetype, link.href)
                        if download_path then
                            new_last_download = new_last_download or link.href
                            local key = pending_key(server.url, link.href)
                            if pending_urls[key] then
                                -- Update file path in case sync_dir or filename settings changed.
                                self.pending_syncs[pending_urls[key]].file = download_path
                            elseif dl_count <= self.sync_max_dl then
                                table.insert(self.pending_syncs, {
                                    file = download_path,
                                    url = link.href,
                                    username = self.root_catalog_username,
                                    password = self.root_catalog_password,
                                    catalog = server.url,
                                })
                                pending_urls[key] = #self.pending_syncs
                                dl_count = dl_count + 1
                            end
                        end
                        break
                    end
                end
            end
        end
    end
    self.sync_server_list[server.url] = true
    if new_last_download then
        logger.dbg("Updating opds last download for server", server.title, "to", new_last_download)
        self:updateFieldInCatalog(server, "last_download", new_last_download)
    end

end

-- Get list of books to download bigger than sync_max_dl
function OPDSBrowser:getSyncDownloadList(url_arg)
    local sync_table = {}
    local fetch_url = url_arg or self.sync_server.url
    local sub_table
    local up_to_date = false
    while #sync_table < self.sync_max_dl and not up_to_date do
        sub_table = self:genItemTableFromURL(fetch_url)
        -- timeout
        if #sub_table == 0 then
            return sync_table
        end
        local count = 1
        local acquisitions_empty = false
        -- For project gutenberg
        while #(sub_table[count].acquisitions or {}) == 0 do
            if sub_table[count].url and util.stringEndsWith(sub_table[count].url, ".opds") then
                acquisitions_empty = true
                break
            end
            if count == #sub_table then
                return sync_table
            end
            count = count + 1
        end
        -- First entry in table is the newest
        -- If already downloaded, return
        local first_href
        if acquisitions_empty then
            first_href = sub_table[count].url
        else
            first_href = sub_table[count].acquisitions[1].href
        end
        if first_href == self.sync_server.last_download and not self.sync_force then
            return nil
        end
        local href
        for i, entry in ipairs(sub_table) do
            if acquisitions_empty then
                if i >= count then
                    href = entry.url
                else
                    href = nil
                end
            else
                local acquisition = entry.acquisitions and entry.acquisitions[1]
                href = acquisition and acquisition.href
            end
            if href then
                if href == self.sync_server.last_download and not self.sync_force then
                    up_to_date = true
                    break
                else
                    table.insert(sync_table, entry)
                end
            end
        end
        if not sub_table.hrefs.next then
            break
        end
        fetch_url = sub_table.hrefs.next
    end
    return sync_table
end

-- Download pending syncs list
function OPDSBrowser:downloadPendingSyncs(auto_sync)
    local dl_list = self.pending_syncs

    local function do_downloads()
        -- Pre-scan: separate duplicates from items to download
        local items_to_download = {}
        local duplicate_list = {}
        for _, item in ipairs(dl_list) do
            if self.sync_server_list[item.catalog] then
                if lfs.attributes(item.file) and not self.sync_force then
                    table.insert(duplicate_list, item)
                else
                    table.insert(items_to_download, item)
                end
            end
        end

        local total = #items_to_download
        local dl_count = 0
        local downloaded_urls = {}

        for idx, item in ipairs(items_to_download) do
            local info
            if not auto_sync then
                info = InfoMessage:new{
                    text = T(_("Downloading %1 of %2…\n(tap to stop)"), idx, total)
                }
                UIManager:show(info)
                UIManager:forceRePaint()
            end

            local completed, success = Trapper:dismissableRunInSubprocess(function()
                return self:downloadFile(item.file, item.url, item.username, item.password)
            end, info)

            if completed then
                if info then UIManager:close(info) end
                if success then
                    dl_count = dl_count + 1
                    downloaded_urls[item.url] = true
                else
                    local temp_path = item.file .. ".download"
                    if lfs.attributes(temp_path) then os.remove(temp_path) end
                end
            else
                local temp_path = item.file .. ".download"
                if lfs.attributes(temp_path) then os.remove(temp_path) end

                if not auto_sync then
                    local stop = Trapper:confirm(
                        T(_("Downloaded %1 of %2.\nStop downloading?"), dl_count, total),
                        _("Continue"), _("Stop"))
                    if stop then break end
                else
                    break
                end
            end
        end

        -- Remove downloaded and duplicate items from pending_syncs
        local dupe_urls = {}
        for _, item in ipairs(duplicate_list) do
            dupe_urls[item.url] = true
        end
        for i = #dl_list, 1, -1 do
            if downloaded_urls[dl_list[i].url] or dupe_urls[dl_list[i].url] then
                table.remove(dl_list, i)
            end
        end

        if dl_count > 0 then
            UIManager:show(Notification:new{
                text = T(N_("1 book downloaded", "%1 books downloaded", dl_count), dl_count)
            })
            logger.dbg("OPDS: Download completed -", dl_count, "books")
        end
        self._manager.updated = true
        return duplicate_list
    end

    local duplicate_list = do_downloads()

    if duplicate_list and #duplicate_list > 0 then
        if auto_sync then
            logger.dbg("OPDS: Auto-sync - skipping", #duplicate_list, "duplicate files")
        else
            local textviewer
            local duplicate_files = { _("These files are already on the device:") }
            for _, entry in ipairs(duplicate_list) do
                table.insert(duplicate_files, entry.file)
            end
            local text = table.concat(duplicate_files, "\n")
            textviewer = TextViewer:new{
                title = _("Duplicate files"),
                text = text,
                buttons_table = {
                    {
                        {
                            text = _("Do nothing"),
                            callback = function()
                                textviewer:onClose()
                            end
                        },
                        {
                            text = _("Overwrite"),
                            callback = function()
                                self.sync_force = true
                                textviewer:onClose()
                                for _, entry in ipairs(duplicate_list) do
                                    table.insert(dl_list, entry)
                                end
                                Trapper:wrap(function()
                                    do_downloads()
                                end)
                            end
                        },
                        {
                            text = _("Download copies"),
                            callback = function()
                                self.sync_force = true
                                textviewer:onClose()
                                local copies_dir = "copies"
                                local original_dir = util.splitFilePathName(duplicate_list[1].file)
                                local copy_download_dir = original_dir .. copies_dir .. "/"
                                util.makePath(copy_download_dir)
                                for _, entry in ipairs(duplicate_list) do
                                    local _, file_name = util.splitFilePathName(entry.file)
                                    entry.file = copy_download_dir .. file_name
                                    table.insert(dl_list, entry)
                                end
                                Trapper:wrap(function()
                                    do_downloads()
                                end)
                            end
                        },
                    },
                },
            }
            UIManager:show(textviewer)
        end
    end
    logger.dbg("OPDS: downloadPendingSyncs fully completed")
end
return OPDSBrowser
