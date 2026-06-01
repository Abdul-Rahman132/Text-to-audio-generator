require "import"
import "com.androlua.Http"
import "cjson"
import "com.androlua.LuaDialog"
import "android.widget.*"
import "android.view.*"
import "android.content.Context"
import "android.content.Intent"
import "android.net.Uri"
import "android.media.MediaPlayer"
import "android.media.PlaybackParams"
import "android.util.Base64"
import "android.os.*"
import "android.graphics.Typeface"
import "android.graphics.drawable.GradientDrawable"
import "java.io.*"
import "android.speech.tts.TextToSpeech"

local context = activity or service
local mainHandler = Handler(Looper.getMainLooper())
local tts = nil
local mainDialog = nil

local savedText = ""
local savedFileName = ""
local isGenerating = false
local currentGenerateBtn = nil
local currentPlayBtn = nil
local currentResultLayout = nil
local currentSpeedValue = 1.0
local selectedVoice = "Puck"
local selectedVoice2 = "Kore"
local isPodcastMode = false
local googleApiKey = ""
local generatedAudioPath = nil
local mediaPlayer = nil
local isPlaying = false

-- Flags for HIDE feature
local appHidden = false
local hiddenGenerating = false

-- Music mode globals
local isMusicMode = false
local selectedMusicStyle = "Romantic Guitar"
local MUSIC_STYLES = {"Romantic Guitar", "Emotional Sad Piano", "Fast Pop Beats", "Soft Acoustic Vibe"}
local musicLyricsText = ""
local musicThemeText = ""
local MUSIC_URLS = {
    ["Romantic Guitar"] = "https://example.com/romantic_guitar.wav",
    ["Emotional Sad Piano"] = "https://example.com/sad_piano.wav",
    ["Fast Pop Beats"] = "https://example.com/pop_beats.wav",
    ["Soft Acoustic Vibe"] = "https://example.com/acoustic_vibe.wav"
}
local maleVoiceForMusic = "Puck"
local femaleVoiceForMusic = "Kore"

local EMOTIONS = {"Neutral", "Happy", "Sad", "Angry", "Excited", "Fearful", "News Anchor", "Whisper", "Narrator", "Friendly"}
local selectedEmotion = "Neutral"

pcall(function()
    Http.setConnTimeout(120000)
    Http.setReadTimeout(120000)
end)

local VOICE_LIST = {
    "Puck", "Kore", "Charon", "Zephyr", "Fenrir", "Leda",
    "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus",
    "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi",
    "Laomedeia", "Achernar", "Alnilam", "Schedar", "Gacrux", "Pulcherrima"
}

local SPEED_LIST = {"1.0x", "1.25x", "1.5x", "1.75x", "2.0x"}
local SPEED_VALUES = {1.0, 1.25, 1.5, 1.75, 2.0}

local selectedModel = "gemini-2.5-flash-preview-tts"
local userText = ""
local userFileName = ""

local activeHttpRequest = nil
local retryCount = 0
local MAX_RETRY = 3
local MAX_CHARS = 8000

local PREFS_NAME = "Gemini_TTS_Pro"
local prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

-- Helper functions
function createGradientDrawable(startColor, endColor, cornerRadius)
    local gradient = GradientDrawable(GradientDrawable.Orientation.TL_BR, {
        tonumber(startColor:gsub("#", "0x")),
        tonumber(endColor:gsub("#", "0x"))
    })
    gradient.setCornerRadius(cornerRadius)
    return gradient
end

function createCardDrawable(bgColor, cornerRadius, strokeColor, strokeWidth)
    local shape = GradientDrawable()
    shape.setColor(tonumber(bgColor:gsub("#", "0x")))
    shape.setCornerRadius(cornerRadius)
    if strokeColor and strokeWidth then
        shape.setStroke(strokeWidth, tonumber(strokeColor:gsub("#", "0x")))
    end
    return shape
end

function initTTS()
    if tts == nil then
        tts = TextToSpeech(context, TextToSpeech.OnInitListener({
            onInit = function(status)
                if status == TextToSpeech.SUCCESS then
                    pcall(function() tts.setLanguage(java.util.Locale.US) end)
                end
            end
        }))
    end
end

function speakFeedback(message)
    initTTS()
    pcall(function() if tts then tts.speak(message, TextToSpeech.QUEUE_FLUSH, nil) end end)
end

function closeAndCleanup()
    if activeHttpRequest ~= nil then 
        pcall(function() activeHttpRequest.cancel() end) 
        activeHttpRequest = nil 
    end
    if mediaPlayer ~= nil then 
        pcall(function() 
            if mediaPlayer.isPlaying() then 
                mediaPlayer.stop() 
            end 
            mediaPlayer.release() 
        end) 
        mediaPlayer = nil 
        isPlaying = false
    end
    deleteOldAudioFile()
    if tts then 
        pcall(function() tts.stop() tts.shutdown() end) 
        tts = nil 
    end
end

function runOnUi(callback) mainHandler.post(Runnable({ run = callback })) end
function delay(ms, callback) Handler(Looper.getMainLooper()).postDelayed(Runnable({ run = callback }), ms) end
function showToast(msg) runOnUi(function() Toast.makeText(context, msg, Toast.LENGTH_LONG).show() end) end
function vibrate(ms) 
    local vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) 
    if vibrator then 
        pcall(function() vibrator.vibrate(ms or 50) end) 
    end 
end

function saveSettings()
    local editor = prefs.edit()
    editor.putString("voice", selectedVoice)
    editor.putString("voice2", selectedVoice2)
    editor.putBoolean("podcastMode", isPodcastMode)
    editor.putString("model", selectedModel)
    editor.putString("apikey", googleApiKey)
    editor.putString("filename", userFileName)
    editor.putBoolean("musicMode", isMusicMode)
    editor.putString("musicStyle", selectedMusicStyle)
    editor.putString("emotion", selectedEmotion)
    editor.apply()
end

function loadSettings()
    selectedVoice = prefs.getString("voice", "Puck")
    selectedVoice2 = prefs.getString("voice2", "Kore")
    isPodcastMode = prefs.getBoolean("podcastMode", false)
    selectedModel = prefs.getString("model", "gemini-2.5-flash-preview-tts")
    googleApiKey = prefs.getString("apikey", "")
    userFileName = prefs.getString("filename", "")
    isMusicMode = prefs.getBoolean("musicMode", false)
    selectedMusicStyle = prefs.getString("musicStyle", "Romantic Guitar")
    selectedEmotion = prefs.getString("emotion", "Neutral")
end

function applyPlaybackSpeed()
    if mediaPlayer and Build.VERSION.SDK_INT >= 23 then
        pcall(function()
            local lp = PlaybackParams()
            lp.setSpeed(currentSpeedValue)
            mediaPlayer.setPlaybackParams(lp)
        end)
    end
end

function initMediaPlayer()
    if mediaPlayer ~= nil then
        if isPlaying then pcall(function() mediaPlayer.stop() end) isPlaying = false end
        pcall(function() mediaPlayer.release() end)
    end
    mediaPlayer = MediaPlayer()
    mediaPlayer.setOnCompletionListener(MediaPlayer.OnCompletionListener({
        onCompletion = function(mp)
            isPlaying = false
            if currentPlayBtn then
                runOnUi(function() currentPlayBtn.setText("PLAY") end)
            end
        end
    }))
end

function togglePlayPause(playBtn)
    if mediaPlayer == nil then showToast("No audio loaded") return false end
    if isPlaying then
        pcall(function() mediaPlayer.pause() end)
        isPlaying = false
        runOnUi(function() playBtn.setText("PLAY") end)
    else
        pcall(function() 
            mediaPlayer.start() 
            applyPlaybackSpeed()
            isPlaying = true
            runOnUi(function() playBtn.setText("PAUSE") end)
        end)
    end
    return true
end

function jumpAudio(seconds)
    if mediaPlayer then
        pcall(function()
            local currentPos = mediaPlayer.getCurrentPosition()
            local duration = mediaPlayer.getDuration()
            local newPos = currentPos + (seconds * 1000)
            if newPos < 0 then newPos = 0 end
            if newPos > duration then newPos = duration end
            mediaPlayer.seekTo(newPos)
            showToast((seconds > 0 and "Forward " or "Rewind ") .. math.abs(seconds) .. "s")
        end)
    end
end

function deleteOldAudioFile()
    if generatedAudioPath then
        pcall(function()
            local oldFile = File(generatedAudioPath)
            if oldFile.exists() then oldFile.delete() end
        end)
        generatedAudioPath = nil
    end
end

function writeWavHeader(outStream, totalAudioLen, sampleRate)
    local sRate = sampleRate or 24000
    local channels = 1
    local bitsPerSample = 16
    local byteRate = sRate * channels * (bitsPerSample / 8)
    local blockAlign = channels * (bitsPerSample / 8)
    local totalSize = totalAudioLen + 36
    
    local function getBytes(val)
        return { val & 0xff, (val >> 8) & 0xff, (val >> 16) & 0xff, (val >> 24) & 0xff }
    end
    
    local totalSizeB = getBytes(totalSize)
    local sampleRateB = getBytes(sRate)
    local byteRateB = getBytes(byteRate)
    local dataLenB = getBytes(totalAudioLen)
    
    local header = {
        0x52, 0x49, 0x46, 0x46, totalSizeB[1], totalSizeB[2], totalSizeB[3], totalSizeB[4],
        0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00,
        channels & 0xff, (channels >> 8) & 0xff, sampleRateB[1], sampleRateB[2], sampleRateB[3], sampleRateB[4],
        byteRateB[1], byteRateB[2], byteRateB[3], byteRateB[4], blockAlign & 0xff, (blockAlign >> 8) & 0xff,
        bitsPerSample & 0xff, (bitsPerSample >> 8) & 0xff, 0x64, 0x61, 0x74, 0x61, dataLenB[1], dataLenB[2], dataLenB[3], dataLenB[4]
    }
    for i = 1, #header do outStream.write(header[i]) end
end

function downloadWithCurrentSpeed()
    if not generatedAudioPath then
        showToast("Generate audio first")
        return false
    end
    
    local fileName = (userFileName ~= "" and userFileName or "audio_" .. os.time()) .. ".wav"
    local downloadDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    if not downloadDir.exists() then downloadDir.mkdirs() end
    local destFile = File(downloadDir, fileName)
    
    local success = pcall(function()
        local fis = FileInputStream(File(generatedAudioPath))
        local fos = FileOutputStream(destFile)
        local buffer = byte[8192]
        while true do
            local len = fis.read(buffer)
            if len == -1 then break end
            fos.write(buffer, 0, len)
        end
        fis.close()
        fos.close()
    end)
    
    if success then
        showToast("Saved: " .. fileName)
        speakFeedback("Download complete")
        local intent = Intent(Intent.ACTION_MEDIA_SCANNER_SCAN_FILE)
        intent.setData(Uri.fromFile(destFile))
        context.sendBroadcast(intent)
        return true
    else
        showToast("Download failed")
        return false
    end
end

-- ========== PODCAST MODE ==========
local function fetchAudioWithTimeout(line, voice, apikey, model, maxRetries, callback)
    local retryCount = 0
    local function attempt()
        local completed = false
        local timeoutHandler = Handler(Looper.getMainLooper())
        local timeoutRunnable = Runnable({
            run = function()
                if not completed then
                    completed = true
                    if activeHttpRequest then pcall(function() activeHttpRequest.cancel() end) end
                    callback(nil, "Timeout")
                end
            end
        })
        timeoutHandler.postDelayed(timeoutRunnable, 60000)
        
        local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apikey
        local requestBody = {
            contents = { { parts = { { text = line } } } },
            generationConfig = {
                responseModalities = {"AUDIO"},
                speechConfig = { voiceConfig = { prebuiltVoiceConfig = { voiceName = voice } } }
            }
        }
        local headers = HashMap()
        headers.put("Content-Type", "application/json")
        
        activeHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
            if completed then return end
            completed = true
            timeoutHandler.removeCallbacks(timeoutRunnable)
            if code == 200 then
                local ok, data = pcall(cjson.decode, content)
                if ok and data and data.candidates and #data.candidates > 0 then
                    local candidate = data.candidates[1]
                    if candidate and candidate.content and candidate.content.parts then
                        for _, part in ipairs(candidate.content.parts) do
                            if part.inlineData and part.inlineData.data then
                                local audioBytes = Base64.decode(part.inlineData.data, Base64.NO_WRAP)
                                callback(audioBytes, nil)
                                return
                            end
                        end
                    end
                end
                callback(nil, "No audio")
            elseif code == 429 and retryCount < maxRetries then
                retryCount = retryCount + 1
                delay(8000, attempt)
            else
                callback(nil, "HTTP " .. code)
            end
        end)
    end
    attempt()
end

function generatePodcast(userText, apikey, hostVoice, guestVoice, model, generateBtn, playBtn, resultLayout)
    local systemPrompt = "Transform the provided text into a natural, engaging podcast conversation between two speakers: 'Host' and 'Guest'. Output strictly a valid JSON array of objects with keys 'speaker' ('host' or 'guest') and 'text'. No markdown. Text: "
    local fullPrompt = systemPrompt .. userText
    local scriptUrl = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" .. apikey
    local scriptBody = {
        contents = { { parts = { { text = fullPrompt } } } },
        generationConfig = { temperature = 0.7 }
    }
    local scriptHeaders = HashMap()
    scriptHeaders.put("Content-Type", "application/json")
    
    activeHttpRequest = Http.post(scriptUrl, cjson.encode(scriptBody), scriptHeaders, function(code, content)
        activeHttpRequest = nil
        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts and #candidate.content.parts > 0 then
                    local raw = candidate.content.parts[1].text
                    if raw then
                        local cleaned = raw:gsub("```json\n?", ""):gsub("\n```", ""):gsub("```", "")
                        local startIdx, endIdx = cleaned:find("%[.*%]")
                        if startIdx then cleaned = cleaned:sub(startIdx, endIdx) end
                        local okJson, dialogue = pcall(cjson.decode, cleaned)
                        if okJson and type(dialogue) == "table" and #dialogue > 0 then
                            local allAudio = {}
                            local index = 1
                            local function process()
                                if index > #dialogue then
                                    local totalLen = 0
                                    for _, chunk in ipairs(allAudio) do totalLen = totalLen + #chunk end
                                    local tempPath = context.getCacheDir().getPath() .. "/podcast_" .. os.time() .. ".wav"
                                    local fos = FileOutputStream(File(tempPath))
                                    writeWavHeader(fos, totalLen, 24000)
                                    for _, chunk in ipairs(allAudio) do fos.write(chunk) end
                                    fos.close()
                                    generatedAudioPath = tempPath
                                    runOnUi(function()
                                        if appHidden then
                                            appHidden = false
                                            hiddenGenerating = false
                                            showMainWithAudio()
                                        else
                                            if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                                            initMediaPlayer()
                                            pcall(function()
                                                mediaPlayer.setDataSource(generatedAudioPath)
                                                mediaPlayer.prepare()
                                                applyPlaybackSpeed()
                                            end)
                                            if playBtn then playBtn.setEnabled(true); playBtn.setText("PLAY") end
                                            if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE PODCAST") end
                                            showToast("Podcast ready!")
                                        end
                                    end)
                                    isGenerating = false
                                    return
                                end
                                local turn = dialogue[index]
                                local voice = (turn.speaker == "host") and hostVoice or guestVoice
                                runOnUi(function() if generateBtn then generateBtn.setText("PODCAST: " .. index .. "/" .. #dialogue) end end)
                                fetchAudioWithTimeout(turn.text, voice, apikey, model, 3, function(audio, err)
                                    if audio then
                                        table.insert(allAudio, audio)
                                        index = index + 1
                                        delay(500, process)
                                    else
                                        runOnUi(function()
                                            if generateBtn then generateBtn.setEnabled(true) end
                                            showToast("Podcast failed at segment " .. index)
                                            if appHidden then
                                                appHidden = false
                                                hiddenGenerating = false
                                                showMain()
                                            end
                                        end)
                                        isGenerating = false
                                    end
                                end)
                            end
                            process()
                            return
                        end
                    end
                end
            end
        end
        runOnUi(function()
            if generateBtn then generateBtn.setEnabled(true) end
            showToast("Script generation failed")
            if appHidden then
                appHidden = false
                hiddenGenerating = false
                showMain()
            end
        end)
        isGenerating = false
    end)
end

-- ========== SINGLE VOICE ==========
function generateSingleAudio(text, voice, apikey, model, generateBtn, playBtn, resultLayout)
    if activeHttpRequest then pcall(function() activeHttpRequest.cancel() end) end
    retryCount = 0
    local trimmedText = text:match("^%s*(.-)%s*$")
    if trimmedText == "" then showToast("Enter text"); isGenerating=false; return end
    if apikey == "" then showToast("API key missing"); isGenerating=false; return end
    
    local emotionPrefix = ""
    if selectedEmotion ~= "Neutral" then
        local emotionMap = {
            ["Happy"] = "Speak in a happy, cheerful tone: ",
            ["Sad"] = "Speak in a sad, melancholic tone: ",
            ["Angry"] = "Speak in an angry, aggressive tone: ",
            ["Excited"] = "Speak in an excited, energetic tone: ",
            ["Fearful"] = "Speak in a fearful, trembling tone: ",
            ["News Anchor"] = "Speak like a professional news anchor, clear and formal: ",
            ["Whisper"] = "Speak in a soft whisper: ",
            ["Narrator"] = "Speak like a calm storyteller: ",
            ["Friendly"] = "Speak in a warm, friendly tone: "
        }
        emotionPrefix = emotionMap[selectedEmotion] or ""
    end
    local finalText = emotionPrefix .. trimmedText
    
    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apikey
    local requestBody = {
        contents = { { parts = { { text = finalText } } } },
        generationConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = { voiceConfig = { prebuiltVoiceConfig = { voiceName = voice } } }
        }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json")
    
    local function makeRequest()
        activeHttpRequest = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
            activeHttpRequest = nil
            if code == 200 then
                local ok, data = pcall(cjson.decode, content)
                if ok and data and data.candidates and #data.candidates > 0 then
                    local candidate = data.candidates[1]
                    if candidate and candidate.content and candidate.content.parts then
                        for _, part in ipairs(candidate.content.parts) do
                            if part.inlineData and part.inlineData.data then
                                local audioBytes = Base64.decode(part.inlineData.data, Base64.NO_WRAP)
                                local tempPath = context.getCacheDir().getPath() .. "/tts_" .. os.time() .. ".wav"
                                local fos = FileOutputStream(File(tempPath))
                                writeWavHeader(fos, #audioBytes, 24000)
                                fos.write(audioBytes)
                                fos.close()
                                generatedAudioPath = tempPath
                                runOnUi(function()
                                    if appHidden then
                                        appHidden = false
                                        hiddenGenerating = false
                                        showMainWithAudio()
                                    else
                                        if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                                        initMediaPlayer()
                                        pcall(function()
                                            mediaPlayer.setDataSource(generatedAudioPath)
                                            mediaPlayer.prepare()
                                            applyPlaybackSpeed()
                                        end)
                                        if playBtn then playBtn.setEnabled(true); playBtn.setText("PLAY") end
                                        if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE AUDIO") end
                                        showToast("Audio ready!")
                                    end
                                end)
                                isGenerating = false
                                return
                            end
                        end
                    end
                end
                runOnUi(function()
                    if generateBtn then generateBtn.setEnabled(true) end
                    showToast("No audio data")
                    if appHidden then
                        appHidden = false
                        hiddenGenerating = false
                        showMain()
                    end
                end)
                isGenerating = false
            elseif code == 429 and retryCount < MAX_RETRY then
                retryCount = retryCount + 1
                delay(10000, makeRequest)
            else
                runOnUi(function()
                    if generateBtn then generateBtn.setEnabled(true) end
                    showToast("Error: " .. code)
                    if appHidden then
                        appHidden = false
                        hiddenGenerating = false
                        showMain()
                    end
                end)
                isGenerating = false
            end
        end)
    end
    makeRequest()
end

-- ========== TEXT TO MUSIC ==========
local SINGING_PROMPT = "Sing the following lyrics in a melodious, expressive singing voice. Stretch vowels, add musical pauses, use dynamic pitch. Lyrics: "

function getVoiceForGender(gender)
    return (gender == "male") and maleVoiceForMusic or femaleVoiceForMusic
end

function generateLyricsFromTheme(theme, userLyrics, apikey, callback)
    local prompt = "You are a songwriter. Generate meaningful song lyrics (max 200 words) based on: " .. theme
    if userLyrics and userLyrics ~= "" then prompt = prompt .. "\nUser lyrics (improve): " .. userLyrics end
    prompt = prompt .. "\nOutput only raw lyrics, no extra text."
    local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" .. apikey
    local body = { contents = { { parts = { { text = prompt } } } }, generationConfig = { temperature = 0.8 } }
    local headers = HashMap()
    headers.put("Content-Type", "application/json")
    
    Http.post(url, cjson.encode(body), headers, function(code, content)
        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts and #candidate.content.parts > 0 then
                    local lyrics = candidate.content.parts[1].text
                    if lyrics and lyrics ~= "" then
                        callback(lyrics, nil)
                        return
                    end
                end
            end
            callback(nil, "No lyrics generated")
        else
            callback(nil, "HTTP " .. code)
        end
    end)
end

function generateSingingScript(lyrics, apikey, callback)
    local systemPrompt = [[
Split the lyrics into a singing duet between male and female. Output JSON array of objects with keys: "speaker" ("male"/"female"), "text" (short phrase max 100 chars), "voice" (Puck/Fenrir/Charon/Zephyr for male, Kore/Aoede/Callirrhoe/Leda for female). No markdown. Lyrics: ]] .. lyrics
    local url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" .. apikey
    local body = { contents = { { parts = { { text = systemPrompt } } } }, generationConfig = { temperature = 0.7 } }
    local headers = HashMap()
    headers.put("Content-Type", "application/json")
    
    Http.post(url, cjson.encode(body), headers, function(code, content)
        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts and #candidate.content.parts > 0 then
                    local raw = candidate.content.parts[1].text
                    if raw then
                        local cleaned = raw:gsub("```json\n?", ""):gsub("\n```", ""):gsub("```", "")
                        local s, e = cleaned:find("%[.*%]")
                        if s then cleaned = cleaned:sub(s, e) end
                        local okj, dialogue = pcall(cjson.decode, cleaned)
                        if okj and type(dialogue) == "table" and #dialogue > 0 then
                            callback(dialogue, nil)
                            return
                        end
                    end
                end
            end
            callback(nil, "Invalid response from AI")
        else
            callback(nil, "HTTP error: " .. code)
        end
    end)
end

function generateSingingChunkWithRetry(text, voice, apikey, model, maxRetries, callback, attempt)
    attempt = attempt or 1
    local apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":generateContent?key=" .. apikey
    local fullText = SINGING_PROMPT .. text
    local requestBody = {
        contents = { { parts = { { text = fullText } } } },
        generationConfig = {
            responseModalities = {"AUDIO"},
            speechConfig = { voiceConfig = { prebuiltVoiceConfig = { voiceName = voice } } }
        }
    }
    local headers = HashMap()
    headers.put("Content-Type", "application/json")
    
    local completed = false
    local timeoutHandler = Handler(Looper.getMainLooper())
    local timeoutRunnable = Runnable({
        run = function()
            if not completed then
                completed = true
                if attempt < maxRetries then
                    showToast("Timeout, retrying chunk (" .. attempt .. "/" .. maxRetries .. ")")
                    delay(5000, function() generateSingingChunkWithRetry(text, voice, apikey, model, maxRetries, callback, attempt+1) end)
                else
                    callback(nil, "Timeout after retries")
                end
            end
        end
    })
    timeoutHandler.postDelayed(timeoutRunnable, 45000)
    
    local http = Http.post(apiUrl, cjson.encode(requestBody), headers, function(code, content)
        if completed then return end
        completed = true
        timeoutHandler.removeCallbacks(timeoutRunnable)
        
        if code == 200 then
            local ok, data = pcall(cjson.decode, content)
            if ok and data and data.candidates and #data.candidates > 0 then
                local candidate = data.candidates[1]
                if candidate and candidate.content and candidate.content.parts then
                    for _, part in ipairs(candidate.content.parts) do
                        if part.inlineData and part.inlineData.data then
                            local audioBytes = Base64.decode(part.inlineData.data, Base64.NO_WRAP)
                            callback(audioBytes, nil)
                            return
                        end
                    end
                end
            end
            callback(nil, "No audio data")
        elseif code == 429 and attempt < maxRetries then
            showToast("Rate limit, retrying chunk (" .. attempt .. "/" .. maxRetries .. ")")
            delay(10000, function() generateSingingChunkWithRetry(text, voice, apikey, model, maxRetries, callback, attempt+1) end)
        elseif attempt < maxRetries then
            showToast("Error " .. code .. ", retrying chunk")
            delay(5000, function() generateSingingChunkWithRetry(text, voice, apikey, model, maxRetries, callback, attempt+1) end)
        else
            callback(nil, "Failed after retries: " .. code)
        end
    end)
end

function mergeAudioChunks(chunksList, outputPath)
    local totalLen = 0
    for _, chunk in ipairs(chunksList) do totalLen = totalLen + #chunk end
    local file = File(outputPath)
    local fos = FileOutputStream(file)
    writeWavHeader(fos, totalLen, 24000)
    for _, chunk in ipairs(chunksList) do fos.write(chunk) end
    fos.close()
    return outputPath
end

function getBackgroundMusicPath(style)
    local url = MUSIC_URLS[style]
    if not url then return nil end
    local cacheDir = context.getCacheDir().getPath()
    local fileName = "bg_" .. style:gsub(" ", "_") .. ".wav"
    local localPath = cacheDir .. "/" .. fileName
    local file = File(localPath)
    if file.exists() then return localPath end
    local success = false
    local thread = Thread(Runnable({
        run = function()
            local result = pcall(function()
                local resp = Http.get(url, nil, function(code, data)
                    if code == 200 then
                        local fos = FileOutputStream(file)
                        fos.write(data:getBytes())
                        fos.close()
                        success = true
                    end
                end)
            end)
        end
    }))
    thread.start()
    thread.join(15000)
    return success and localPath or nil
end

function mixAudioWithBackground(vocalPath, bgPath, outputPath)
    local function readPCM(path)
        local fis = FileInputStream(File(path))
        local header = byte[44]
        fis.read(header)
        local all = {}
        local buffer = byte[8192]
        while true do
            local len = fis.read(buffer)
            if len == -1 then break end
            table.insert(all, buffer:sub(1, len))
        end
        fis.close()
        return table.concat(all)
    end
    
    local vocalPCM = readPCM(vocalPath)
    local bgPCM = readPCM(bgPath)
    local minLen = math.min(#vocalPCM, #bgPCM)
    local mixed = byte[#vocalPCM]
    for i = 1, minLen, 2 do
        local vSample = (vocalPCM[i+1] or 0)*256 + (vocalPCM[i] or 0)
        if vSample > 32767 then vSample = vSample - 65536 end
        local bSample = (bgPCM[i+1] or 0)*256 + (bgPCM[i] or 0)
        if bSample > 32767 then bSample = bSample - 65536 end
        local mixedSample = vSample * 1.0 + bSample * 0.35
        if mixedSample > 32767 then mixedSample = 32767 elseif mixedSample < -32768 then mixedSample = -32768 end
        local intSample = math.floor(mixedSample + 0.5)
        mixed[i] = intSample & 0xFF
        mixed[i+1] = (intSample >> 8) & 0xFF
    end
    for i = minLen+1, #vocalPCM do mixed[i] = vocalPCM[i] end
    local fos = FileOutputStream(File(outputPath))
    writeWavHeader(fos, #mixed, 24000)
    fos.write(mixed)
    fos.close()
    return outputPath
end

function generateMusicFromDialogue(dialogue, style, apikey, model, generateBtn, playBtn, resultLayout)
    local total = #dialogue
    local allAudio = {}
    local current = 1
    local failedChunks = {}
    
    local function processNext()
        if current > total then
            if #allAudio == 0 then
                runOnUi(function()
                    if generateBtn then generateBtn.setEnabled(true) end
                    showToast("No audio chunks generated.")
                    if appHidden then
                        appHidden = false
                        hiddenGenerating = false
                        showMain()
                    end
                    isGenerating = false
                end)
                return
            end
            local tempVocal = context.getCacheDir().getPath() .. "/vocal_" .. os.time() .. ".wav"
            mergeAudioChunks(allAudio, tempVocal)
            local bgPath = getBackgroundMusicPath(style)
            if not bgPath then
                runOnUi(function()
                    if generateBtn then generateBtn.setEnabled(true) end
                    showToast("Background not available, vocals only")
                    generatedAudioPath = tempVocal
                    if appHidden then
                        appHidden = false
                        hiddenGenerating = false
                        showMainWithAudio()
                    else
                        if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                        initMediaPlayer()
                        pcall(function()
                            mediaPlayer.setDataSource(generatedAudioPath)
                            mediaPlayer.prepare()
                            applyPlaybackSpeed()
                            mediaPlayer.start()
                            isPlaying = true
                            if playBtn then playBtn.setText("PAUSE") end
                        end)
                        if playBtn then playBtn.setEnabled(true) end
                        if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE MUSIC") end
                    end
                end)
                isGenerating = false
                return
            end
            local finalPath = context.getCacheDir().getPath() .. "/final_music_" .. os.time() .. ".wav"
            mixAudioWithBackground(tempVocal, bgPath, finalPath)
            generatedAudioPath = finalPath
            runOnUi(function()
                if appHidden then
                    appHidden = false
                    hiddenGenerating = false
                    showMainWithAudio()
                else
                    if resultLayout then resultLayout.setVisibility(View.VISIBLE) end
                    initMediaPlayer()
                    pcall(function()
                        mediaPlayer.setDataSource(generatedAudioPath)
                        mediaPlayer.prepare()
                        applyPlaybackSpeed()
                        mediaPlayer.start()
                        isPlaying = true
                        if playBtn then playBtn.setText("PAUSE") end
                    end)
                    if playBtn then playBtn.setEnabled(true) end
                    if generateBtn then generateBtn.setEnabled(true); generateBtn.setText("REGENERATE MUSIC") end
                    local msg = "Music ready! " .. #allAudio .. "/" .. total .. " chunks"
                    if #failedChunks > 0 then msg = msg .. " (" .. #failedChunks .. " skipped)" end
                    showToast(msg)
                end
            end)
            isGenerating = false
            return
        end
        
        local seg = dialogue[current]
        local speaker = seg.speaker
        local lyric = seg.text
        local voice = seg.voice or getVoiceForGender(speaker)
        runOnUi(function() if generateBtn then generateBtn.setText("MUSIC: " .. current .. "/" .. total .. " (" .. string.upper(speaker) .. ")") end end)
        
        generateSingingChunkWithRetry(lyric, voice, apikey, model, 10, function(audio, err)
            if audio then
                table.insert(allAudio, audio)
                current = current + 1
                delay(1000, processNext)
            else
                showToast("Skipping chunk " .. current .. ": " .. (err or "unknown"))
                table.insert(failedChunks, current)
                current = current + 1
                delay(500, processNext)
            end
        end)
    end
    processNext()
end

function generateMusicWithTheme(theme, userLyrics, style, apikey, model, generateBtn, playBtn, resultLayout)
    if userLyrics and userLyrics ~= "" then
        generateSingingScript(userLyrics, apikey, function(dialogue, err)
            if err or not dialogue then
                runOnUi(function() 
                    if generateBtn then generateBtn.setEnabled(true) end
                    showToast("Script failed: " .. tostring(err))
                    if appHidden then
                        appHidden = false
                        hiddenGenerating = false
                        showMain()
                    end
                end)
                isGenerating = false
                return
            end
            generateMusicFromDialogue(dialogue, style, apikey, model, generateBtn, playBtn, resultLayout)
        end)
    elseif theme and theme ~= "" then
        runOnUi(function() if generateBtn then generateBtn.setText("Generating lyrics...") end end)
        generateLyricsFromTheme(theme, "", apikey, function(lyrics, err)
            if err or not lyrics then
                runOnUi(function() 
                    if generateBtn then generateBtn.setEnabled(true) end
                    showToast("Lyrics failed")
                    if appHidden then
                        appHidden = false
                        hiddenGenerating = false
                        showMain()
                    end
                end)
                isGenerating = false
                return
            end
            runOnUi(function() if generateBtn then generateBtn.setText("Creating duet script...") end end)
            generateSingingScript(lyrics, apikey, function(dialogue, err2)
                if err2 or not dialogue then
                    runOnUi(function() 
                        if generateBtn then generateBtn.setEnabled(true) end
                        showToast("Script failed")
                        if appHidden then
                            appHidden = false
                            hiddenGenerating = false
                            showMain()
                        end
                    end)
                    isGenerating = false
                    return
                end
                generateMusicFromDialogue(dialogue, style, apikey, model, generateBtn, playBtn, resultLayout)
            end)
        end)
    else
        runOnUi(function() 
            if generateBtn then generateBtn.setEnabled(true) end
            showToast("Enter theme or lyrics")
            if appHidden then
                appHidden = false
                hiddenGenerating = false
                showMain()
            end
        end)
        isGenerating = false
    end
end

-- ========== API SETTINGS DIALOG ==========
function showApiSettings(isFirstRun)
    local views = {}
    local layout = {
        LinearLayout, orientation = "vertical", padding = "24dp", layout_width = "fill", layout_height = "wrap", id = "apiDialogCard",
        { TextView, id = "welcomeText", text = isFirstRun and "Welcome to Gemini TTS Pro!\n\nPlease enter your Google Gemini API key to start." or "API CONFIGURATION", textSize = isFirstRun and 18 or 16, textColor = "#FFFFFF", gravity = "center", paddingBottom = "20dp", typeface = Typeface.DEFAULT_BOLD },
        { EditText, id = "apiInput", hint = "Enter your Google Gemini API key", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", padding = "12dp", textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" },
        {
            LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", layout_marginTop = "20dp",
            { Button, id = "testBtn", text = "TEST", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp" },
            { Button, id = "saveBtn", text = "SAVE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", layout_marginLeft = "6dp" },
            { Button, id = "closeBtn", text = "CLOSE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", layout_marginLeft = "6dp" }
        }
    }
    local dlg = LuaDialog(context)
    dlg.setView(loadlayout(layout, views))
    pcall(function()
        views.apiDialogCard.setBackground(createGradientDrawable("#1A1A2E", "#16213E", 20))
        views.apiInput.setBackground(createCardDrawable("#0F3460", 12, "#E94560", 1))
        views.testBtn.setBackground(createGradientDrawable("#F39C12", "#E67E22", 16))
        views.saveBtn.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 16))
        views.closeBtn.setBackground(createGradientDrawable("#7F8C8D", "#95A5A6", 16))
    end)
    views.apiInput.setText(googleApiKey)
    views.testBtn.onClick = function()
        vibrate(30)
        local key = views.apiInput.getText().toString()
        if key == "" then showToast("Enter API key") return end
        views.testBtn.setText("Testing...")
        views.testBtn.setEnabled(false)
        Http.get("https://generativelanguage.googleapis.com/v1beta/models?key=" .. key, nil, function(code, content)
            runOnUi(function()
                views.testBtn.setText("TEST")
                views.testBtn.setEnabled(true)
                if code == 200 then showToast("Valid key") else showToast("Invalid key: " .. code) end
            end)
        end)
    end
    views.saveBtn.onClick = function()
        vibrate(30)
        googleApiKey = views.apiInput.getText().toString()
        saveSettings()
        if isFirstRun then
            local editor = prefs.edit()
            editor.putBoolean("firstRun", false)
            editor.apply()
        end
        dlg.dismiss()
        showMain()
    end
    views.closeBtn.onClick = function()
        vibrate(30)
        dlg.dismiss()
        if googleApiKey == "" then closeAndCleanup() else showMain() end
    end
    dlg.show()
end

-- ========== PROFESSIONAL ABOUT DIALOG (Redesigned as per instructions) ==========
function showAboutDialog()
    -- Detailed instructions text (scrollable)
    local instructionsText = [[
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ Text to Audio Mode
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Select "Text to Audio" from Mode dropdown
• Choose from 24+ premium AI voices
• Select an emotion (Happy, Sad, Angry, Excited, 
  Fearful, News Anchor, Whisper, Narrator, Friendly)
• Type your story/script in the text box
• Click GENERATE AUDIO button
• Adjust playback speed (1.0x - 2.0x)
• Save audio with custom filename
• Downloaded files go to Downloads folder

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ Text to Music Mode
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Select "Text to Music" from Mode dropdown
• Choose a music style:
  - Romantic Guitar
  - Emotional Sad Piano
  - Fast Pop Beats
  - Soft Acoustic Vibe
• Either write your own lyrics in "Lyrics" field
  OR enter a song theme/situation (e.g., "A sad 
  romantic song between a boy and a girl")
• Click GENERATE MUSIC
• AI creates a male+female singing duet with 
  background music automatically
• Music will play when ready

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ Text to Podcast Mode
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Select "Text to Podcast" from Mode dropdown
• Choose Host Voice and Guest Voice separately
• Enter your script or story in the text box
• Click GENERATE PODCAST
• AI converts text into a natural conversation 
  between two speakers (Host & Guest)
• Each segment is generated with proper voice

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ HIDE Button (Background Generation)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• While audio/music/podcast is generating, 
  tap HIDE button
• The extension will close completely
• Generation continues in background
• When generation completes, the extension 
  automatically reopens with your audio ready
• Perfect for long generations without waiting

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ EXIT Button
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Tap EXIT to close the extension
• Stops any ongoing generation
• Cleans up all resources
• Use HIDE if you want to keep generating

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
■ Additional Features
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• 24+ realistic AI voices (Puck, Kore, Fenrir, etc.)
• 10 emotional styles for TTS
• 4 music background styles
• Custom save file names
• Playback speed control
• Audio player with seek (10s forward/backward)
• Download to device storage
• Automatic app reopening after background generation
]]
    
    local views = {}
    local layout = {
        LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "aboutCard",
        -- Developer name at top
        { TextView, id = "devName", text = "Developer: Abdul Rehman", textSize = 18, textColor = "#E94560", gravity = "center", paddingTop = "16dp", paddingBottom = "8dp", typeface = Typeface.DEFAULT_BOLD },
        -- How to Use heading
        { TextView, id = "howToHeading", text = "HOW TO USE", textSize = 16, textColor = "#FFFFFF", gravity = "center", paddingBottom = "12dp", typeface = Typeface.DEFAULT_BOLD },
        -- Scrollable instructions
        { ScrollView, layout_width = "fill", layout_height = "0dp", layout_weight = "1",
            { TextView, id = "instructionsText", text = instructionsText, textSize = 12, textColor = "#CCCCCC", padding = "16dp", typeface = Typeface.MONOSPACE }
        },
        -- Buttons at bottom
        {
            LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", padding = "16dp",
            { Button, id = "feedbackBtn", text = "SEND FEEDBACK", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "14dp", layout_marginRight = "8dp", textSize = 14, typeface = Typeface.DEFAULT_BOLD },
            { Button, id = "closeAboutBtn", text = "CLOSE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "14dp", layout_marginLeft = "8dp", textSize = 14, typeface = Typeface.DEFAULT_BOLD }
        }
    }
    
    local dlg = LuaDialog(context)
    dlg.setTitle(nil)
    dlg.setView(loadlayout(layout, views))
    dlg.setCancelable(true)
    
    pcall(function()
        views.aboutCard.setBackground(createCardDrawable("#0F0F1A", 20, "#2C2C44", 1))
        views.instructionsText.setBackground(createCardDrawable("#1A1A2E", 12, nil, nil))
        views.feedbackBtn.setBackground(createGradientDrawable("#25D366", "#128C7E", 24))
        views.closeAboutBtn.setBackground(createGradientDrawable("#7F8C8D", "#95A5A6", 24))
        local param = dlg.getWindow().getAttributes()
        param.dimAmount = 0.6
        dlg.getWindow().setAttributes(param)
    end)
    
    views.feedbackBtn.onClick = function()
        vibrate(40)
        if mainDialog then mainDialog.dismiss() end
        dlg.dismiss()
        local phone = "+923124255300"
        local message = "Hello Abdul Rehman! I'm using Gemini Advanced TTS. Here is my feedback:"
        local url = "https://wa.me/" .. phone:gsub("+", "") .. "?text=" .. Uri.encode(message)
        local intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        context.startActivity(intent)
        closeAndCleanup()
        os.exit()
    end
    
    views.closeAboutBtn.onClick = function()
        vibrate(30)
        dlg.dismiss()
    end
    
    dlg.show()
end

-- ========== FUNCTION TO REOPEN WITH AUDIO ==========
function showMainWithAudio()
    runOnUi(function()
        showMain()
        delay(500, function()
            if mainDialog and generatedAudioPath then
                if currentResultLayout then
                    currentResultLayout.setVisibility(View.VISIBLE)
                    initMediaPlayer()
                    pcall(function()
                        mediaPlayer.setDataSource(generatedAudioPath)
                        mediaPlayer.prepare()
                        applyPlaybackSpeed()
                    end)
                    if currentPlayBtn then
                        currentPlayBtn.setEnabled(true)
                        currentPlayBtn.setText("PLAY")
                    end
                    if currentGenerateBtn then
                        currentGenerateBtn.setEnabled(true)
                        if isMusicMode then
                            currentGenerateBtn.setText("REGENERATE MUSIC")
                        elseif isPodcastMode then
                            currentGenerateBtn.setText("REGENERATE PODCAST")
                        else
                            currentGenerateBtn.setText("REGENERATE AUDIO")
                        end
                    end
                    showToast("Audio ready!")
                end
            end
        end)
    end)
end

-- ========== MAIN UI ==========
function showMain()
    loadSettings()
    initMediaPlayer()
    initTTS()
    appHidden = false
    hiddenGenerating = false
    
    local views = {}
    local scrollLayout = {
        ScrollView, layout_width = "fill", layout_height = "fill", id = "windowBackground",
        {
            LinearLayout, orientation = "vertical", padding = "20dp", layout_width = "fill", layout_height = "wrap",
            { TextView, text = "Gemini Advanced TTS", textSize = 24, textColor = "#FFFFFF", gravity = "center", paddingTop = "10dp", typeface = Typeface.DEFAULT_BOLD },
            { TextView, text = "Professional AI Voice & Music Generator", textSize = 13, textColor = "#CCCCCC", gravity = "center", paddingBottom = "20dp", typeface = Typeface.create(Typeface.DEFAULT, Typeface.ITALIC) },
            {
                LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", layout_marginBottom = "15dp",
                { TextView, text = "Mode:", textSize = 14, textColor = "#FFFFFF", layout_width = "wrap", layout_marginRight = "12dp" },
                { Spinner, id = "modeSpinner", layout_width = "0dp", layout_weight = "1", layout_height = "45dp" }
            },
            -- Common text box
            {
                LinearLayout, id = "commonTextLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = (not isMusicMode) and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "cardText", padding = "12dp", layout_marginBottom = "15dp",
                    { EditText, id = "textInput", hint = "Type your story or script here...", layout_width = "fill", layout_height = "130dp", backgroundColor = "#00000000", padding = "10dp", gravity = Gravity.TOP, textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            -- Audio mode settings
            {
                LinearLayout, id = "audioSettingsLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = (not isMusicMode and not isPodcastMode) and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", id = "cardSettings", padding = "15dp", layout_marginBottom = "15dp",
                    { TextView, text = "Select Voice", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD },
                    { Spinner, id = "voiceSpin", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "12dp" },
                    { TextView, text = "Emotion / Style", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "emotionSpin", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "12dp" },
                    { TextView, text = "Playback Speed", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD },
                    { Spinner, id = "speedSpin", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "15dp" },
                    { TextView, text = "Save File Name", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD },
                    { EditText, id = "fileNameInput", hint = "e.g. my_audio_file", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", paddingTop = "8dp", paddingBottom = "8dp", textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            -- Music mode settings
            {
                LinearLayout, id = "musicSettingsLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = isMusicMode and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", padding = "15dp", layout_marginBottom = "15dp", id = "musicCard",
                    { TextView, text = "Music Style", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "styleSpinner", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "15dp" },
                    { TextView, text = "Lyrics (Optional)", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "lyricsInput", hint = "Write your own lyrics or leave empty", layout_width = "fill", layout_height = "100dp", backgroundColor = "#00000000", padding = "10dp", gravity = Gravity.TOP, textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF", layout_marginBottom = "15dp" },
                    { TextView, text = "Song Theme / Situation", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { EditText, id = "themeInput", hint = "e.g., 'A sad romantic song between a boy and a girl'", layout_width = "fill", layout_height = "80dp", backgroundColor = "#00000000", padding = "10dp", gravity = Gravity.TOP, textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            -- Podcast mode settings
            {
                LinearLayout, id = "podcastSettingsLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = isPodcastMode and View.VISIBLE or View.GONE,
                {
                    LinearLayout, orientation = "vertical", layout_width = "fill", layout_height = "wrap", padding = "15dp", layout_marginBottom = "15dp", id = "podcastCard",
                    { TextView, text = "Host Voice", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "hostVoiceSpin", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "12dp" },
                    { TextView, text = "Guest Voice", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "6dp" },
                    { Spinner, id = "guestVoiceSpin", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "12dp" },
                    { TextView, text = "Playback Speed", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD },
                    { Spinner, id = "speedSpinPodcast", layout_width = "fill", layout_height = "45dp", layout_marginBottom = "15dp" },
                    { TextView, text = "Save File Name", textSize = 12, textColor = "#CCCCCC", typeface = Typeface.DEFAULT_BOLD },
                    { EditText, id = "fileNameInputPodcast", hint = "e.g. my_podcast", layout_width = "fill", layout_height = "wrap", backgroundColor = "#00000000", paddingTop = "8dp", paddingBottom = "8dp", textSize = 14, textColor = "#FFFFFF", hintTextColor = "#80FFFFFF" }
                }
            },
            { Button, id = "generateBtn", text = (isMusicMode and "GENERATE MUSIC") or (isPodcastMode and "GENERATE PODCAST" or "GENERATE AUDIO"), layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", padding = "16dp", textSize = 15, typeface = Typeface.DEFAULT_BOLD, layout_marginBottom = "15dp" },
            {
                LinearLayout, id = "resultLayout", orientation = "vertical", layout_width = "fill", layout_height = "wrap", visibility = View.GONE, layout_marginBottom = "15dp", padding = "15dp",
                { TextView, text = "AUDIO PLAYER", textSize = 12, textColor = "#2ECC71", gravity = "center", layout_marginBottom = "10dp", typeface = Typeface.DEFAULT_BOLD },
                {
                    LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", gravity = "center",
                    { Button, id = "rwBtn", text = "⏪ 10s", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", layout_marginRight = "6dp", padding = "12dp" },
                    { Button, id = "playBtn", text = "PLAY", layout_width = "0dp", layout_weight = "1.4", textColor = "#FFFFFF", layout_marginRight = "6dp", enabled = false, typeface = Typeface.DEFAULT_BOLD, padding = "12dp" },
                    { Button, id = "ffBtn", text = "10s ⏩", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp" }
                },
                { Button, id = "downloadBtn", text = "DOWNLOAD", layout_width = "fill", layout_height = "wrap", textColor = "#FFFFFF", layout_marginTop = "12dp", padding = "12dp" }
            },
            {
                LinearLayout, orientation = "horizontal", layout_width = "fill", layout_height = "wrap", paddingTop = "10dp",
                { Button, id = "apiBtn", text = "API", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD, layout_marginRight = "4dp" },
                { Button, id = "hideBtn", text = "HIDE", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD, layout_marginRight = "4dp" },
                { Button, id = "aboutBtn", text = "ABOUT", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD, layout_marginRight = "4dp" },
                { Button, id = "exitBtn", text = "EXIT", layout_width = "0dp", layout_weight = "1", textColor = "#FFFFFF", padding = "12dp", typeface = Typeface.DEFAULT_BOLD }
            }
        }
    }
    
    local dlg = LuaDialog(context)
    dlg.setCancelable(false)
    dlg.setView(loadlayout(scrollLayout, views))
    mainDialog = dlg
    currentGenerateBtn = views.generateBtn
    currentPlayBtn = views.playBtn
    currentResultLayout = views.resultLayout
    dlg.setOnDismissListener({ onDismiss = function() 
        if not hiddenGenerating then
            closeAndCleanup()
        end
    end })
    
    -- Professional Styling
    pcall(function()
        views.windowBackground.setBackground(createGradientDrawable("#0F0F1A", "#1A1A2E", 24))
        views.cardText.setBackground(createCardDrawable("#1A1A2E", 16, "#2C2C44", 1))
        if views.cardSettings then views.cardSettings.setBackground(createCardDrawable("#1A1A2E", 16, "#2C2C44", 1)) end
        if views.musicCard then views.musicCard.setBackground(createCardDrawable("#1A1A2E", 16, "#2C2C44", 1)) end
        if views.podcastCard then views.podcastCard.setBackground(createCardDrawable("#1A1A2E", 16, "#2C2C44", 1)) end
        
        if views.voiceSpin then views.voiceSpin.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        if views.emotionSpin then views.emotionSpin.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        if views.speedSpin then views.speedSpin.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        if views.fileNameInput then views.fileNameInput.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        
        if views.styleSpinner then views.styleSpinner.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        if views.lyricsInput then views.lyricsInput.setBackground(createCardDrawable("#16213E", 12, "#E94560", 1)) end
        if views.themeInput then views.themeInput.setBackground(createCardDrawable("#16213E", 12, "#E94560", 1)) end
        
        if views.hostVoiceSpin then views.hostVoiceSpin.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        if views.guestVoiceSpin then views.guestVoiceSpin.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        if views.speedSpinPodcast then views.speedSpinPodcast.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        if views.fileNameInputPodcast then views.fileNameInputPodcast.setBackground(createCardDrawable("#16213E", 10, "#E94560", 1)) end
        
        views.textInput.setBackground(createCardDrawable("#16213E", 12, "#E94560", 1))
        views.generateBtn.setBackground(createGradientDrawable("#E94560", "#C62A40", 30))
        views.resultLayout.setBackground(createCardDrawable("#0F3460", 20, "#E94560", 1))
        views.rwBtn.setBackground(createGradientDrawable("#2C3E50", "#34495E", 20))
        views.playBtn.setBackground(createGradientDrawable("#27AE60", "#2ECC71", 20))
        views.ffBtn.setBackground(createGradientDrawable("#2C3E50", "#34495E", 20))
        views.downloadBtn.setBackground(createGradientDrawable("#E67E22", "#F39C12", 20))
        views.apiBtn.setBackground(createGradientDrawable("#8E44AD", "#9B59B6", 20))
        views.hideBtn.setBackground(createGradientDrawable("#2980B9", "#3498DB", 20))
        views.aboutBtn.setBackground(createGradientDrawable("#F39C12", "#E67E22", 20))
        views.exitBtn.setBackground(createGradientDrawable("#C0392B", "#E74C3C", 20))
    end)
    
    if savedText ~= "" then views.textInput.setText(savedText); userText = savedText end
    if savedFileName ~= "" then
        if views.fileNameInput then views.fileNameInput.setText(savedFileName) end
        if views.fileNameInputPodcast then views.fileNameInputPodcast.setText(savedFileName) end
        userFileName = savedFileName
    end
    
    views.textInput.addTextChangedListener({ afterTextChanged = function(e) userText = e.toString(); savedText = userText end })
    
    if views.fileNameInput then
        views.fileNameInput.addTextChangedListener({ afterTextChanged = function(e) userFileName = e.toString(); savedFileName = userFileName; saveSettings() end })
    end
    if views.fileNameInputPodcast then
        views.fileNameInputPodcast.addTextChangedListener({ afterTextChanged = function(e) userFileName = e.toString(); savedFileName = userFileName; saveSettings() end })
    end
    
    -- Mode Spinner
    local MODES = {"Text to Audio", "Text to Music", "Text to Podcast"}
    local modeAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, MODES)
    modeAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
    views.modeSpinner.setAdapter(modeAdapter)
    local modeIndex = 0
    if isMusicMode then modeIndex = 1
    elseif isPodcastMode then modeIndex = 2
    else modeIndex = 0 end
    views.modeSpinner.setSelection(modeIndex)
    
    views.modeSpinner.onItemSelectedListener = {
        onItemSelected = function(p, v, pos, id)
            if pos == 0 then
                isMusicMode = false
                isPodcastMode = false
                views.commonTextLayout.setVisibility(View.VISIBLE)
                views.audioSettingsLayout.setVisibility(View.VISIBLE)
                views.musicSettingsLayout.setVisibility(View.GONE)
                views.podcastSettingsLayout.setVisibility(View.GONE)
                views.generateBtn.setText("GENERATE AUDIO")
            elseif pos == 1 then
                isMusicMode = true
                isPodcastMode = false
                views.commonTextLayout.setVisibility(View.GONE)
                views.audioSettingsLayout.setVisibility(View.GONE)
                views.musicSettingsLayout.setVisibility(View.VISIBLE)
                views.podcastSettingsLayout.setVisibility(View.GONE)
                views.generateBtn.setText("GENERATE MUSIC")
            else
                isMusicMode = false
                isPodcastMode = true
                views.commonTextLayout.setVisibility(View.VISIBLE)
                views.audioSettingsLayout.setVisibility(View.GONE)
                views.musicSettingsLayout.setVisibility(View.GONE)
                views.podcastSettingsLayout.setVisibility(View.VISIBLE)
                views.generateBtn.setText("GENERATE PODCAST")
            end
            saveSettings()
        end
    }
    
    -- Audio mode controls
    if views.voiceSpin then
        local voiceAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
        voiceAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.voiceSpin.setAdapter(voiceAdapter)
        for i, v in ipairs(VOICE_LIST) do if v == selectedVoice then views.voiceSpin.setSelection(i-1) end end
        views.voiceSpin.onItemSelectedListener = { onItemSelected = function(p,v,pos) selectedVoice = VOICE_LIST[pos+1]; saveSettings() end }
    end
    
    if views.emotionSpin then
        local emotionAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, EMOTIONS)
        emotionAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.emotionSpin.setAdapter(emotionAdapter)
        for i, e in ipairs(EMOTIONS) do if e == selectedEmotion then views.emotionSpin.setSelection(i-1) end end
        views.emotionSpin.onItemSelectedListener = {
            onItemSelected = function(p, v, pos, id)
                selectedEmotion = EMOTIONS[pos+1]
                saveSettings()
            end
        }
    end
    
    if views.speedSpin then
        local speedAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, SPEED_LIST)
        speedAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.speedSpin.setAdapter(speedAdapter)
        for i, v in ipairs(SPEED_VALUES) do if v == currentSpeedValue then views.speedSpin.setSelection(i-1) end end
        views.speedSpin.onItemSelectedListener = { onItemSelected = function(p,v,pos) currentSpeedValue = SPEED_VALUES[pos+1]; applyPlaybackSpeed() end }
    end
    
    -- Music mode controls
    if views.styleSpinner then
        local styleAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, MUSIC_STYLES)
        styleAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.styleSpinner.setAdapter(styleAdapter)
        for i, s in ipairs(MUSIC_STYLES) do if s == selectedMusicStyle then views.styleSpinner.setSelection(i-1) end end
        views.styleSpinner.onItemSelectedListener = { onItemSelected = function(p,v,pos) selectedMusicStyle = MUSIC_STYLES[pos+1]; saveSettings() end }
    end
    
    -- Podcast mode controls
    if views.hostVoiceSpin then
        local hostAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
        hostAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.hostVoiceSpin.setAdapter(hostAdapter)
        for i, v in ipairs(VOICE_LIST) do if v == selectedVoice then views.hostVoiceSpin.setSelection(i-1) end end
        views.hostVoiceSpin.onItemSelectedListener = { onItemSelected = function(p,v,pos) selectedVoice = VOICE_LIST[pos+1]; saveSettings() end }
    end
    
    if views.guestVoiceSpin then
        local guestAdapter = ArrayAdapter(context, android.R.layout.simple_spinner_item, VOICE_LIST)
        guestAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.guestVoiceSpin.setAdapter(guestAdapter)
        for i, v in ipairs(VOICE_LIST) do if v == selectedVoice2 then views.guestVoiceSpin.setSelection(i-1) end end
        views.guestVoiceSpin.onItemSelectedListener = { onItemSelected = function(p,v,pos) selectedVoice2 = VOICE_LIST[pos+1]; saveSettings() end }
    end
    
    if views.speedSpinPodcast then
        local speedAdapterPod = ArrayAdapter(context, android.R.layout.simple_spinner_item, SPEED_LIST)
        speedAdapterPod.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        views.speedSpinPodcast.setAdapter(speedAdapterPod)
        for i, v in ipairs(SPEED_VALUES) do if v == currentSpeedValue then views.speedSpinPodcast.setSelection(i-1) end end
        views.speedSpinPodcast.onItemSelectedListener = { onItemSelected = function(p,v,pos) currentSpeedValue = SPEED_VALUES[pos+1]; applyPlaybackSpeed() end }
    end
    
    -- Player controls
    views.rwBtn.onClick = function() vibrate(30); jumpAudio(-10) end
    views.ffBtn.onClick = function() vibrate(30); jumpAudio(10) end
    views.playBtn.onClick = function()
        vibrate(30)
        if not generatedAudioPath then showToast("Generate audio first") return end
        if mediaPlayer == nil then
            initMediaPlayer()
            pcall(function() mediaPlayer.setDataSource(generatedAudioPath); mediaPlayer.prepare(); applyPlaybackSpeed() end)
        end
        togglePlayPause(views.playBtn)
    end
    views.downloadBtn.onClick = function() vibrate(40); downloadWithCurrentSpeed() end
    
    -- Generate button
    views.generateBtn.onClick = function()
        vibrate(35)
        if isGenerating then showToast("Already generating...") return end
        if googleApiKey == "" then showToast("Set API key first"); dlg.dismiss(); showApiSettings(false); return end
        
        if isMusicMode then
            local lyrics = views.lyricsInput.getText().toString()
            local theme = views.themeInput.getText().toString()
            if theme == "" and lyrics == "" then
                showToast("Enter theme or lyrics")
                return
            end
        else
            local currentText = views.textInput.getText().toString()
            if currentText == "" then showToast("Enter text") return end
            userText = currentText
        end
        
        if mediaPlayer then
            if isPlaying then pcall(function() mediaPlayer.stop() end) end
            pcall(function() mediaPlayer.release() end)
            mediaPlayer = nil
        end
        deleteOldAudioFile()
        views.playBtn.setEnabled(false)
        views.playBtn.setText("PLAY")
        views.resultLayout.setVisibility(View.GONE)
        isPlaying = false
        isGenerating = true
        views.generateBtn.setEnabled(false)
        
        if isMusicMode then
            local lyrics = views.lyricsInput.getText().toString()
            local theme = views.themeInput.getText().toString()
            views.generateBtn.setText("GENERATING MUSIC...")
            generateMusicWithTheme(theme, lyrics, selectedMusicStyle, googleApiKey, selectedModel, views.generateBtn, views.playBtn, views.resultLayout)
        elseif isPodcastMode then
            views.generateBtn.setText("GENERATING PODCAST...")
            generatePodcast(userText, googleApiKey, selectedVoice, selectedVoice2, selectedModel, views.generateBtn, views.playBtn, views.resultLayout)
        else
            views.generateBtn.setText("GENERATING AUDIO...")
            generateSingleAudio(userText, selectedVoice, googleApiKey, selectedModel, views.generateBtn, views.playBtn, views.resultLayout)
        end
    end
    
    -- HIDE button
    views.hideBtn.onClick = function()
        vibrate(30)
        if isGenerating then
            appHidden = true
            hiddenGenerating = true
            mainDialog.dismiss()
            showToast("App hidden, generation continues...")
        else
            showToast("No generation in progress")
        end
    end
    
    -- ABOUT button
    views.aboutBtn.onClick = function()
        vibrate(30)
        showAboutDialog()
    end
    
    views.apiBtn.onClick = function() vibrate(35); dlg.dismiss(); showApiSettings(false) end
    views.exitBtn.onClick = function() vibrate(35); dlg.dismiss(); closeAndCleanup() end
    dlg.show()
end

-- ========== STARTUP ==========
loadSettings()
local firstRun = prefs.getBoolean("firstRun", true)
if googleApiKey == "" or firstRun then
    if firstRun then
        showApiSettings(true)
    else
        showApiSettings(false)
    end
else
    showMain()
end