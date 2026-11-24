-- Skip boot logos and the MM6/7/8 intro movies Merge plays after continent pick.
-- In-game story cutscenes are left alone.

function events.ShowMovie(t)
	local n = string.lower(t.Name or "")
	n = n:gsub('["%s]', "")
	if n == "intro" or n == "7intro" or n == "6intro" then
		t.Allow = false
	end
end
