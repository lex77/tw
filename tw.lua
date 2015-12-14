#!/usr/bin/lua
-- TwiWe
--
-- Require: LuaTwit, xml, lua-gd, luafilesystem

local argparse = require "argparse"
local gd       = require "gd"
local lfs      = require "lfs"
local curl     = require "luacurl"
local xml      = require "xml"
local twitter  = require "luatwit"
local c        = curl.new()

function round(num, idp)
    -- Округляем число num до idp
    local mult = 10^(idp or 0)
    return math.floor(num * mult + 0.5) / mult
end

function strlen(unicode_string)
    -- Считаем правильную длину строки. Костыль для unicode
    local _, count = string.gsub(unicode_string, "[^\128-\193]", "")
    return count
end

function file_exists(name)
    -- Проверка существования файла
    local f=io.open(name,"r")
    if f~=nil then io.close(f) return true else return false end
end

function getTemperature(t)
	-- Берём значение температуры и добавляем перед ним "+", если оно положительное
	if tonumber(t) > 0 then t = "+"..t end
	return t
end

function getUrl(url)
    -- Get URL
    c:setopt(curl.OPT_URL, url)
    local t = {} -- this will collect resulting chunks
    c:setopt(curl.OPT_WRITEFUNCTION, function (param, buf)
        table.insert(t, buf) -- store a chunk of data received
        return #buf
    end)
    c:setopt(curl.OPT_PROGRESSFUNCTION, function(param, dltotal, dlnow)
        --print('%', url, dltotal, dlnow)
    end)
    c:setopt(curl.OPT_NOPROGRESS, false) -- activate progress
    assert(c:perform())
    return table.concat(t) -- return the whole data as a string
end

function getAvatar (name_ru, name_en, t, season)
	-- Generate avatar image
    local src       = TW_CFG_GLOBAL.PATH.."/city/"..name_en.."/avatar_"..season..".jpg"
    local font_name = TW_CFG_GLOBAL.PATH.."/fonts/"..TW_CFG_GLOBAL.AVA_FONT_NAME
    local font_t    = TW_CFG_GLOBAL.PATH.."/fonts/"..TW_CFG_GLOBAL.AVA_FONT_T
    
    if file_exists(src) == false then
        src = TW_CFG_GLOBAL.PATH.."/city/"..name_en.."/avatar_default.jpg"
    end

    if file_exists(src) == false then
        src = TW_CFG_GLOBAL.PATH.."/img/avatar_"..season..".jpg"
    end

    if file_exists(src) == false then
        print ("Source avatar image not found. Exit.")
        os.exit()
    end

    local im  	= gd.createFromJpeg( src )
    local white = im:colorAllocate( 255, 255, 255 )
    local gray	= im:colorAllocate( 64, 64, 64 )
    im:stringFT( gray, font_name, 36, 0, 9, 50, name_ru  )
    im:stringFT( white, font_name, 36, 0, 10, 52, name_ru  )

    im:stringFT( gray, font_t, 72, 0, 9, 218, t  )
    im:stringFT( white, font_t, 72, 0, 10, 220, t  )

    return im:jpegStr(90)
end

function getWd (wdcode)
    -- Russian wind direction
    local wd = {
        ['n']  = 'северный',
        ['s']  = 'южный',
        ['w']  = 'западный',
        ['e']  = 'восточный',
        ['sw'] = 'юго-западный',
        ['se'] = 'юго-восточный',
        ['nw'] = 'северо-западный',
        ['ne'] = 'северо-восточный'
    }
    return wd[wdcode]
end
  
function getDateRu ()
    -- Real russian date :-)
    local month_ru = {
        ['01'] = 'января',
        ['02'] = 'февраля',
        ['03'] = 'марта',
        ['04'] = 'апреля',
        ['05'] = 'мая',
        ['06'] = 'июня',
        ['07'] = 'июля',
        ['08'] = 'августа',
        ['09'] = 'сентября',
        ['10'] = 'октября',
        ['11'] = 'ноября',
        ['12'] = 'декабря'
    }

    local weekday_ru = {
        ['1'] = 'Понедельник',
        ['2'] = 'Вторник',
        ['3'] = 'Среда',
        ['4'] = 'Четверг',
        ['5'] = 'Пятница',
        ['6'] = 'Суббота',
        ['0'] = 'Воскресенье'
    }

    return weekday_ru[os.date('%w')]..', '..tonumber(os.date('%d'))..' '..month_ru[os.date('%m')]..' '..os.date('%Y')..' года'
end

function parseXml (in_xml)
    -- Ya XML parsing
    local xmldata = xml.load(in_xml)
    local function tomorrow() 
        -- Get tomorrow
        local d = tonumber(os.date("%d"))+1
        if d < 10 then d = "0"..d end
        return os.date("%Y-%m-")..d
    end

    local function parseTable(table)
        -- Parse table
        local result = {}
        for i, val in ipairs(table) do
            if type(val[1]) ~= "table" then result[val.xml] = val[1] end
        end
        return result
    end

    local we = {
        -- Ищем и находим погоду на сегодня и завтра
        today = xml.find(xmldata,"day","date",os.date("%Y-%m-%d")),
        tomorrow = xml.find(xmldata,"day","date",tomorrow())
    }

    local result = {
        fact = parseTable(xml.find(xmldata,"fact")),
        today = {},
        today = parseTable(we.today),
        tomorrow = {},
    }

    for i, val in ipairs({"morning","day","evening"}) do
        result.today[val] = parseTable(xml.find(we.today,"day_part","type",val))
    end
    
    for i, val in ipairs({"night","morning","day","evening"}) do
        result.tomorrow[val] = parseTable(xml.find(we.tomorrow,"day_part","type",val))
    end

    return result
end

function composeWeatherMessages (msgtypes, data)
    -- Генерация твитов о погоде и не только о ней
    local result = {}

    local function stdMessage(in_data)
        -- генерируем стандартную часть погодного твита
        local result = nil
        local temperature = nil

        if in_data.temperature_from ~= nil then
            temperature = getTemperature(in_data.temperature_from).."…"..getTemperature(in_data.temperature_to)
        else
            temperature = getTemperature(in_data.temperature)
        end

        result = temperature.."°C, "..in_data.weather_type..".\n"

        if tonumber(in_data.wind_speed) == 0 then
            result = result.."Штиль, ветер молчит.\n"
        else
            result = result.."Ветер "..getWd(in_data.wind_direction)..", "..round(in_data.wind_speed,0).." м/с.\n"
        end

        return result.."Давление "..in_data.pressure.." мм.рт.ст.,\nвлажность "..in_data.humidity.."% "
    end

    for i, val in ipairs(msgtypes) do
        if val == "first" then
            -- Твит, отправляемый однократно, каждое утро. Дата, восход и закат солнца и луны.
            result[i] = getDateRu()..", XXI век.\n"
            result[i] = result[i].."Восход Солнца в "..data.today.sunrise..", закат в "..data.today.sunset..".\n"
            result[i] = result[i].."Восход Луны в "..data.today.moonrise..", закат в "..data.today.moonset.."."
        elseif val == "now" then
            result[i] = "Сейчас "..stdMessage(data.fact)
        elseif val == "morning" then
            result[i] = "Утром "..stdMessage(data.today.morning)
        elseif val == "day" then
            result[i] = "Днём "..stdMessage(data.today.day)
        elseif val == "evening" then
            result[i] = "Вечером "..stdMessage(data.today.evening)
        elseif val == "night" then
            result[i] = "Ночью "..stdMessage(data.tomorrow.night)
        elseif val == "tm_morning" then
            result[i] = "Завтра утром "..stdMessage(data.tomorrow.morning)
        elseif val == "tm_day" then
            result[i] = "Завтра днём "..stdMessage(data.tomorrow.day)
        end
    end

    return result
end

function getXmlData(name_en, city_id)
    -- Скачиваем .xml с погодой у Яндекса,
    -- проверяем время создания файла, если прошло менее 3-х часов, не дёргаем яндекс
    -- при необходимости создаём соответствующие директории
    local citydir = TW_CFG_GLOBAL.PATH.."/city/"..name_en.."/"
    local xmlfile = citydir..city_id..".xml"
    local wdata = nil

    local function getandwrite(xmlfile)
        -- Скачивание и запись файла с погодой.
        -- Возвращаем содержимое файла
        local x = getUrl(TW_CFG_GLOBAL.YAXML..city_id..".xml")
        local file = io.open (xmlfile ,'w+')
        io.output (file)
        io.write (x)
        io.close (file)
        return x
    end

    print("Getting xml data for "..name_en)

    -- Проверяем существование директории города, если нет - создаём
    if file_exists(citydir) == false then
        print("City dir not found, creating")
        lfs.mkdir(citydir)
    end

    if file_exists(xmlfile) == true then
        local lastmod = os.time()-lfs.attributes(xmlfile).change

        if lastmod > tonumber(TW_CFG_GLOBAL.DLTIMEOUT) then
            print("Local weather data not actual, try to download new")
            return getandwrite(xmlfile)
        else
            local file = io.open (xmlfile ,'r')
            io.input (file)
            wdata = io.read ('*a')
            io.close (file)
            return wdata
        end
    else
        print("Local weather data not found, downloading...")
        wdata = getandwrite(xmlfile)
        return wdata
    end
end

function logger(level, message)
    -- Писатель логов
    print(os.date().." "..level..": "..message)
end

-- -------------------------------------------------------------
--
--
local parser = argparse("weather", "Weather twitter bot.")
parser:option("-c --config", "Configuration file.", "config.lua")

local args = parser:parse()

if file_exists(args.config) == false then
    print ("ERROR: Configuration file not found")
    os.exit(1)
else
    dofile(args.config)
end


logger("INFO", "Weather Bot init")

for i, city in ipairs(TW_CFG_CITY) do
    logger("INFO", "Processing config for "..city.name_en)
    for key, value in pairs(city.hours) do
        if key == os.date("%H") then
            logger("INFO", "Current hour is "..os.date("%H")..". Found in config. Processing...")
            
            local xmlweather = getXmlData(city.name_en,city.ya_city_id)
            local weather    = parseXml(xmlweather)
            local avatar     = getAvatar(city.name_ru, city.name_en, getTemperature(weather.fact.temperature).."°", weather.fact.season)
            local messages   = composeWeatherMessages (value, weather)
            local client     = twitter.api.new(city.auth)
            local user, err  = client:set_profile_image{ image = base64.encode(avatar) }

            for k, msg in ipairs(messages) do
                local msglen = strlen(msg)
                
                if msglen<138-strlen(city.name_ru) then
                    msg = msg.." #"..city.name_ru;
                end -- Добавим хэштег с городом если влезает

                local msglen = strlen(msg)

                if msglen<132 then
                    msg = msg.." #погода"
                end

                local tw, err = client:tweet{status = msg, lat = tonumber(city.lat), long = tonumber(city.long), place_id = city.place_id}
            end                
        end
    end
end
