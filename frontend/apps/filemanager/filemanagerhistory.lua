local BD = require("ui/bidi")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local ConfirmBox = require("ui/widget/confirmbox")
local DocSettings = require("docsettings")
local FFIUtil = require("ffi/util")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local _ = require("gettext")
local T = FFIUtil.template

local FileManagerHistory = InputContainer:extend{
    hist_menu_title = _("History"),
}

local status_text = {
    all = _("All"),
    reading = _("Reading"),
    abandoned = _("On hold"),
    complete = _("Finished"),
    deleted = _("Deleted"),
    new = _("New"),
}

function FileManagerHistory:init()
    self.ui.menu:registerToMainMenu(self)
end

function FileManagerHistory:addToMainMenu(menu_items)
    -- insert table to main tab of filemanager menu
    menu_items.history = {
        text = self.hist_menu_title,
        callback = function()
            self:onShowHist()
        end,
    }
end

function FileManagerHistory:updateItemTable()
    -- try to stay on current page
    local select_number = nil
    if self.hist_menu.page and self.hist_menu.perpage and self.hist_menu.page > 0 then
        select_number = (self.hist_menu.page - 1) * self.hist_menu.perpage + 1
    end
    self.count = { all = #require("readhistory").hist,
        reading = 0, abandoned = 0, complete = 0, deleted = 0, new = 0, }
    local item_table = {}
    for _, v in ipairs(require("readhistory").hist) do
        if not self.filter or v.status == self.filter then
            table.insert(item_table, v)
        end
        if self.statuses_fetched then
            self.count[v.status] = self.count[v.status] + 1
        end
    end
    local title = self.hist_menu_title
    if self.filter then
        title = title .. " (" .. status_text[self.filter] .. ")"
    end
    self.hist_menu:switchItemTable(title, item_table, select_number)
end

function FileManagerHistory:onSetDimensions(dimen)
    self.dimen = dimen
end

function FileManagerHistory:onMenuHold(item)
    local readerui_instance = require("apps/reader/readerui"):_getRunningInstance()
    local currently_opened_file = readerui_instance and readerui_instance.document and readerui_instance.document.file
    self.histfile_dialog = nil
    local buttons = {
        {
            {
                text = _("Reset settings"),
                enabled = item.file ~= currently_opened_file and DocSettings:hasSidecarFile(FFIUtil.realpath(item.file)),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Reset settings for this document?\n\n%1\n\nAny highlights or bookmarks will be permanently lost."),
                            BD.filepath(item.file)),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            filemanagerutil.purgeSettings(item.file)
                            require("readhistory"):fileSettingsPurged(item.file)
                            self._manager:updateItemTable()
                            UIManager:close(self.histfile_dialog)
                        end,
                    })
                end,
            },
            {
                text = _("Remove from history"),
                callback = function()
                    require("readhistory"):removeItem(item)
                    self._manager:updateItemTable()
                    UIManager:close(self.histfile_dialog)
                end,
            },
        },
        {
            {
                text = _("Delete"),
                enabled = (item.file ~= currently_opened_file and lfs.attributes(item.file, "mode")) and true or false,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Are you sure that you want to delete this document?\n\n%1\n\nIf you delete a file, it is permanently lost."),
                            BD.filepath(item.file)),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local FileManager = require("apps/filemanager/filemanager")
                            FileManager:deleteFile(item.file)
                            require("readhistory"):fileDeleted(item.file) -- (will update "lastfile" if needed)
                            self._manager:updateItemTable()
                            UIManager:close(self.histfile_dialog)
                        end,
                    })
                end,
            },
            {
                text = _("Book information"),
                enabled = FileManagerBookInfo:isSupported(item.file),
                callback = function()
                    FileManagerBookInfo:show(item.file)
                    UIManager:close(self.histfile_dialog)
                end,
             },
        },
    }
    self.histfile_dialog = ButtonDialogTitle:new{
        title = BD.filename(item.text:match("([^/]+)$")),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(self.histfile_dialog)
    return true
end

-- Can't *actually* name it onSetRotationMode, or it also fires in FM itself ;).
function FileManagerHistory:MenuSetRotationModeHandler(rotation)
    if rotation ~= nil and rotation ~= Screen:getRotationMode() then
        UIManager:close(self._manager.hist_menu)
        -- Also re-layout ReaderView or FileManager itself
        if self._manager.ui.view and self._manager.ui.view.onSetRotationMode then
            self._manager.ui.view:onSetRotationMode(rotation)
        elseif self._manager.ui.onSetRotationMode then
            self._manager.ui:onSetRotationMode(rotation)
        else
            Screen:setRotationMode(rotation)
        end
        self._manager:onShowHist()
    end
    return true
end

function FileManagerHistory:onShowHist()
    self.hist_menu = Menu:new{
        ui = self.ui,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true, -- hint for UIManager:_repaint()
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() self:showHistDialog() end,
        onMenuHold = self.onMenuHold,
        onSetRotationMode = self.MenuSetRotationModeHandler,
        _manager = self,
    }

    self:updateItemTable()
    self.hist_menu.close_callback = function()
        self.statuses_fetched = nil
        self.filter = nil
        UIManager:close(self.hist_menu)
    end
    UIManager:show(self.hist_menu)
    return true
end

function FileManagerHistory:showHistDialog()
    if not self.statuses_fetched then
        local status
        for _, v in ipairs(require("readhistory").hist) do
            if v.dim then
                status = "deleted"
            else
                if DocSettings:hasSidecarFile(v.file) then
                    local docinfo = DocSettings:open(v.file) -- no io handles created, do not close
                    if docinfo.data.summary and docinfo.data.summary.status
                            and docinfo.data.summary.status ~= "" then
                        status = docinfo.data.summary.status
                    else
                        status = "reading"
                    end
                else
                    status = "new"
                end
            end
            v.status = status
            self.count[status] = self.count[status] + 1
        end
        self.statuses_fetched = true
    end

    local hist_dialog
    local buttons = {}
    local function genFilterButton(status)
        return {
            text = T(_("%1 (%2)"), status_text[status], self.count[status]),
            callback = function()
                UIManager:close(hist_dialog)
                self.filter = status ~= "all" and status
                self:updateItemTable()
            end,
        }
    end
    table.insert(buttons, {
        genFilterButton("reading"),
        genFilterButton("abandoned"),
    })
    table.insert(buttons, {
        genFilterButton("complete"),
        genFilterButton("deleted"),
    })
    table.insert(buttons, {
        genFilterButton("all"),
        genFilterButton("new"),
    })
    if self.count.deleted > 0 then
        table.insert(buttons, {})
        table.insert(buttons, {
            {
                text = _("Clear history of deleted files"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Clear history of deleted files?"),
                        ok_text = _("Clear"),
                        ok_callback = function()
                            UIManager:close(hist_dialog)
                            require("readhistory"):clearMissing()
                            self:updateItemTable()
                        end,
                    })
                end,
             },
        })
    end
    hist_dialog = ButtonDialogTitle:new{
        title = _("Filter by book status"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(hist_dialog)
end

return FileManagerHistory
