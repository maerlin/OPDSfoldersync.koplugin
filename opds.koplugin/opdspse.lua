local http = require("socket.http")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")
local ltn12 = require("ltn12")
local RenderImage = require("ui/renderimage")
local Screen = require("device").screen
local socket = require("socket")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local url = require("socket.url")
local _ = require("gettext")
local T = require("ffi/util").template

local OPDSPSE = {}

local function redactURLForLog(value)
    if type(value) ~= "string" then return value end
    return value
        :gsub("(/opds/)[^/]+(/image)", "%1…%2")
        :gsub("([?&][^=]*[Kk]ey=)[^&]+", "%1…")
        :gsub("([?&][Tt]oken=)[^&]+", "%1…")
end

-- This function attempts to pull chapter progress from Kavita.
function OPDSPSE.getLastPage(remote_url, username, password)
    if type(remote_url) ~= "string" then return 0 end

    -- Create Kavita API URLs from page-stream URLs. Non-Kavita streams simply have no progress.
    local chapter = remote_url:match("[?&]chapterId=([^&]+)")
    local api_key = remote_url:match("/opds/([^/]+)/image")
    local api_base = remote_url:match("(.+)/api")
    if not chapter or not api_key or not api_base then
        return 0
    end

    chapter = url.unescape(chapter)
    api_key = url.unescape(api_key)
    local progress_url = api_base .. "/api/Reader/get-progress?chapterId=" .. url.escape(chapter)
    local auth_url = api_base .. "/api/Plugin/authenticate?apiKey=" .. url.escape(api_key)
        .. "&pluginName=KOReader-OPDS"

    -- Do an HTTP POST to get the Bearer Token for authentication of the /api/Reader/get-progress endpoint.
    local auth_parsed = url.parse(auth_url)
    local auth_data = {}
    local auth_code, auth_headers, auth_status
    if auth_parsed and (auth_parsed.scheme == "http" or auth_parsed.scheme == "https") then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
        local ok, request_code, request_headers, request_status = pcall(function()
            return socket.skip(1, http.request {
                method = "POST",
                url         = auth_url,
                headers     = {
                    ["Accept-Encoding"] = "identity",
                    ["Authentication"] = api_key,
                },
                sink        = ltn12.sink.table(auth_data),
                user        = username,
                password    = password,
            })
        end)
        socketutil:reset_timeout()
        if ok then
            auth_code, auth_headers, auth_status = request_code, request_headers, request_status
        else
            auth_status = request_code
        end
    else
        UIManager:show(InfoMessage:new {
            text = T(_("Invalid protocol:\n%1"), auth_parsed and auth_parsed.scheme or _("unknown")),
        })
    end

    if auth_code == 200 then
        -- If auth succeeded, pull bearer token and then request chapter progress.
        local bearer_token = table.concat(auth_data):match('"token"%s*:%s*"([^"]+)"')
        if not bearer_token then
            logger.dbg("OPDSPSE:getLastPage: Authentication response did not contain a token")
            return 0
        end

        -- Do HTTP GET request for chapter progress.
        local progress_parsed = url.parse(progress_url)
        local progress_data = {}
        local progress_code, progress_headers, progress_status
        if progress_parsed and (progress_parsed.scheme == "http" or progress_parsed.scheme == "https") then
            socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
            local ok, request_code, request_headers, request_status = pcall(function()
                return socket.skip(1, http.request {
                    url         = progress_url,
                    headers     = {
                        ["Accept-Encoding"] = "identity",
                        ["Authorization"] = "Bearer "..bearer_token,
                    },
                    sink        = ltn12.sink.table(progress_data),
                    user        = username,
                    password    = password,
                })
            end)
            socketutil:reset_timeout()
            if ok then
                progress_code, progress_headers, progress_status = request_code, request_headers, request_status
            else
                progress_status = request_code
            end
        else
            UIManager:show(InfoMessage:new {
                text = T(_("Invalid protocol:\n%1"), progress_parsed and progress_parsed.scheme or _("unknown")),
            })
        end

        if progress_code == 200 then
            -- If HTTP GET was successful, pull page number from response.
            return tonumber(table.concat(progress_data):match('"pageNum"%s*:%s*(%d+)')) or 0
        else
            logger.dbg("OPDSPSE:getLastPage: Progress Request failed:", progress_status or progress_code)
            logger.dbg("OPDSPSE:getLastPage: Progress Response headers:",
                progress_headers and socketutil.redact_headers(progress_headers) or nil)
        end
    else
        logger.dbg("OPDSPSE:getLastPage: Authentication Request failed:", auth_status or auth_code)
        logger.dbg("OPDSPSE:getLastPage: Authentication Response headers:",
            auth_headers and socketutil.redact_headers(auth_headers) or nil)
    end

    -- Return page number. If the HTTP requests were unsuccessful, default to 0.
    return 0
end

function OPDSPSE:streamPages(remote_url, count, continue, username, password, last_page_read)
    if type(remote_url) ~= "string" then
        UIManager:show(InfoMessage:new {
            text = _("Invalid stream URL."),
        })
        return
    end
    count = math.max(1, tonumber(count) or 1)

    -- Attempt to pull chapter progress from Kavita when supported.
    -- We have to pull the progress here, otherwise the creation of the page_table
    -- will overwrite the book progress before we pull it, making it always 0.
    local last_page = 0
    if type(remote_url) == "string" and remote_url:find("chapterId=", 1, true) then
        local ok, result = pcall(function() return self:getLastPage(remote_url, username, password) end)
        if ok then
            last_page = tonumber(result) or 0
        else
            logger.warn("Couldn't pull progress, defaulting to Page 0.")
        end
    end
    local page_table = {image_disposable = true}
    setmetatable(page_table, {__index = function (_, key)
        if type(key) ~= "number" then
            local error_bb = RenderImage:renderImageFile("resources/koreader.png", false)
            return error_bb
        else
            local index = key - 1
            local page_url = remote_url:gsub("{pageNumber}", tostring(index))
            page_url = page_url:gsub("{maxWidth}", tostring(Screen:getWidth()))
            local page_data = {}

            logger.dbg("Streaming page from", redactURLForLog(page_url))
            local parsed = url.parse(page_url)

            local code, headers, status
            if parsed and (parsed.scheme == "http" or parsed.scheme == "https") then
                socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                local ok, request_code, request_headers, request_status = pcall(function()
                    return socket.skip(1, http.request {
                        url         = page_url,
                        headers     = {
                            ["Accept-Encoding"] = "identity",
                        },
                        sink        = ltn12.sink.table(page_data),
                        user        = username,
                        password    = password,
                    })
                end)
                socketutil:reset_timeout()
                if ok then
                    code, headers, status = request_code, request_headers, request_status
                else
                    status = request_code
                end
            else
                UIManager:show(InfoMessage:new {
                    text = T(_("Invalid protocol:\n%1"), parsed and parsed.scheme or _("unknown")),
                })
            end

            local data = table.concat(page_data)
            if code == 200 then
                local page_bb = RenderImage:renderImageData(data, #data, false)
                             or RenderImage:renderImageFile("resources/koreader.png", false)
                return page_bb
            else
                logger.dbg("OPDSBrowser:streamPages: Request failed:", status or code)
                logger.dbg("OPDSBrowser:streamPages: Response headers:",
                    headers and socketutil.redact_headers(headers) or nil)
                local error_bb = RenderImage:renderImageFile("resources/koreader.png", false)
                return error_bb
            end
        end
    end})
    local ImageViewer = require("ui/widget/imageviewer")
    local viewer = ImageViewer:new{
        image = page_table,
        fullscreen = true,
        with_title_bar = false,
        image_disposable = false, -- instead set page_table image_disposable to true
        images_list_nb = count,
    }
    UIManager:show(viewer)
    if continue then
        self:jumpToPage(viewer, count)
    elseif last_page_read then
        viewer:switchToImageNum(math.min(math.max(1, tonumber(last_page_read) or 1), count))
    else
        -- Add 1 since Kavita's page count is zero-based and ImageViewer is not.
        viewer:switchToImageNum(math.min(math.max(1, last_page + 1), count))
    end
end

-- Shows a page number dialog for page streaming.
function OPDSPSE.jumpToPage(viewer, count)
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Enter page number"),
        input_type = "number",
        input_hint = "(" .. "1 - " .. count .. ")",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Stream"),
                    is_enter_default = true,
                    callback = function()
                        local page_num = input_dialog:getInputValue()
                        if page_num then
                            UIManager:close(input_dialog)
                            viewer:switchToImageNum(math.min(math.max(1, page_num), count))
                        end
                    end,
                },
            }
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return OPDSPSE
