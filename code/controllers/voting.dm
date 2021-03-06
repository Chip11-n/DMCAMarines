var/datum/controller/vote/vote = new()

var/global/list/round_voters = list() //Keeps track of the individuals voting for a given round, for use in forcedrafting.

datum/controller/vote
	var/initiator = null
	var/started_time = null
	var/time_remaining = 0
	var/mode = null
	var/question = null
	var/list/choices = list()
	var/list/voted = list()
	var/list/voting = list()
	var/list/current_votes = list()
	var/list/additional_text = list()
	var/auto_muted = 0

	New()
		if(vote != src)
			if(istype(vote))
				cdel(vote)
			vote = src

	proc/process()	//called by master_controller
		if(mode)
			// No more change mode votes after the game has started.
			// 3 is GAME_STATE_PLAYING, but that #define is undefined for some reason
			if(mode == "gamemode" && ticker.current_state >= 2)
				to_chat(world, "<b>Voting aborted due to game start.</b>")
				src.reset()
				return

			// Calculate how much time is remaining by comparing current time, to time of vote start,
			// plus vote duration
			time_remaining = round((started_time + config.vote_period - world.time)/10)

			if(time_remaining < 0)
				result()
				for(var/client/C in voting)
					if(C)
						C << browse(null,"window=vote;can_close=0")
				reset()
			else
				for(var/client/C in voting)
					if(C)
						C << browse(vote.interface(C),"window=vote;can_close=0")

				voting.Cut()

	proc/autogamemode()
		initiate_vote("gamemode","the server")
		log_debug("The server has called a gamemode vote")

	proc/reset()
		initiator = null
		time_remaining = 0
		mode = null
		question = null
		choices.Cut()
		voted.Cut()
		voting.Cut()
		current_votes.Cut()
		additional_text.Cut()

	/*	if(auto_muted && !ooc_allowed)
			auto_muted = 0
			ooc_allowed = !( ooc_allowed )
			to_chat(world, "<b>The OOC channel has been automatically enabled due to vote end.</b>")
			log_admin("OOC was toggled automatically due to vote end.")
			message_admins("OOC has been toggled on automatically.")
	*/

	proc/get_result()
		//get the highest number of votes
		var/greatest_votes = 0
		var/total_votes = 0
		for(var/option in choices)
			var/votes = choices[option]
			total_votes += votes
			if(votes > greatest_votes)
				greatest_votes = votes
		//default-vote for everyone who didn't vote
		if(!config.vote_no_default && choices.len)
			var/non_voters = (clients.len - total_votes)
			if(non_voters > 0)
				if(mode == "restart")
					choices["Continue Playing"] += non_voters
					if(choices["Continue Playing"] >= greatest_votes)
						greatest_votes = choices["Continue Playing"]
				else if(mode == "gamemode")
					if(master_mode in choices)
						choices[master_mode] += non_voters
						if(choices[master_mode] >= greatest_votes)
							greatest_votes = choices[master_mode]


		//get all options with that many votes and return them in a list
		. = list()
		if(greatest_votes)
			for(var/option in choices)
				if(choices[option] == greatest_votes)
					. += option
		return .

	proc/announce_result()
		var/list/winners = get_result()
		var/text
		if(winners.len > 0)
			if(winners.len > 1)
				if(mode != "gamemode" || ticker.hide_mode == 0) // Here we are making sure we don't announce potential game modes
					text = "<b>Vote Tied Between:</b>\n"
					for(var/option in winners)
						text += "\t[option]\n"
			. = pick(winners)

			for(var/key in current_votes)
				if(choices[current_votes[key]] == .)
					round_voters += key // Keep track of who voted for the winning round.
			if((mode == "gamemode" && . == "extended") || ticker.hide_mode == 0) // Announce Extended gamemode, but not other gamemodes
				text += "<b>Vote Result: [.]</b>"
			else
				if(mode != "gamemode")
					text += "<b>Vote Result: [.]</b>"
				else
					text += "<b>The vote has ended.</b>" // What will be shown if it is a gamemode vote that isn't extended

		else
			text += "<b>Vote Result: Inconclusive - No Votes!</b>"
		log_vote(text)
		to_chat(world, "<font color='purple'>[text]</font>")
		return .

	proc/result()
		. = announce_result()
		var/restart = 0
		if(.)
			switch(mode)
				if("restart")
					if(. == "Restart Round")
						restart = 1
				if("gamemode")
					if(master_mode != .)
						world.save_mode(.)
						if(ticker && ticker.mode)
							restart = 1
						else
							master_mode = .

		if(mode == "gamemode") //fire this even if the vote fails.
			if(!going)
				going = 1
				to_chat(world, "<font color='red'><b>The round will start soon.</b></font>")

		if(restart)
			to_chat(world, "World restarting due to vote...")
			feedback_set_details("end_error","restart vote")
			if(blackbox)	blackbox.save_all_data_to_sql()
			sleep(50)
			log_game("Rebooting due to restart vote")
			world.Reboot()

		return .

	proc/submit_vote(var/ckey, var/vote)
		if(mode)
			if(config.vote_no_dead && usr.stat == DEAD && !usr.client.holder)
				return 0
			if(current_votes[ckey])
				choices[choices[current_votes[ckey]]]--
			if(vote && 1<=vote && vote<=choices.len)
				voted += usr.ckey
				choices[choices[vote]]++	//check this
				current_votes[ckey] = vote
				return vote
		return 0

	proc/initiate_vote(var/vote_type, var/initiator_key)
		if(!mode)
			if(started_time != null && !check_rights(R_ADMIN))
				var/next_allowed_time = (started_time + config.vote_delay)
				if(next_allowed_time > world.time)
					return 0

			reset()
			switch(vote_type)
				if("restart")
					choices.Add("Restart Round","Continue Playing")
				if("gamemode")
					if(ticker.current_state >= 2)
						return 0
					choices.Add(config.votable_modes)
					var/list/L = subtypesof(/datum/game_mode)
					for (var/F in choices)
						for (var/T in L)
							var/datum/game_mode/M = new T()
							if (M.config_tag == F)
								additional_text.Add("<td align = 'center'>[M.required_players]</td>")
								break
				if("custom")
					question = stripped_input(usr,"What is the vote for?")
					if(!question)	return 0
					for(var/i=1,i<=10,i++)
						var/option = capitalize(stripped_input(usr,"Please enter an option or hit cancel to finish"))
						if(!option || mode || !usr.client)	break
						choices.Add(option)
				else			return 0
			mode = vote_type
			initiator = initiator_key
			started_time = world.time
			var/text = "[capitalize(mode)] vote started by [initiator]."
			if(mode == "custom")
				text += "\n[question]"

			log_vote(text)
			to_chat(world, "<font color='purple'><b>[text]</b>\nType vote to place your votes.\nYou have [config.vote_period/10] seconds to vote.</font>")
			switch(vote_type)
				if("gamemode")
					world << sound('sound/ambience/alarm4.ogg', repeat = 0, wait = 0, volume = 50, channel = 1)
				if("custom")
					world << sound('sound/ambience/alarm4.ogg', repeat = 0, wait = 0, volume = 50, channel = 1)
			if(mode == "gamemode" && going)
				going = 0
				to_chat(world, "<font color='red'><b>Round start has been delayed.</b></font>")



			time_remaining = round(config.vote_period/10)
			return 1
		return 0

	proc/interface(var/client/C)
		if(!C)	return
		var/admin = 0
		var/trialmin = 0
		if(C.holder)
			if(C.holder.rights & R_ADMIN)
				admin = 1
				trialmin = 1 // don't know why we use both of these it's really weird, but I'm 2 lasy to refactor this all to use just admin.
		voting |= C

		. = "<html>[UTF_CHARSET]<head><title>Voting Panel</title></head><body>"
		if(mode)
			if(question)	. += "<h2>Vote: '[question]'</h2>"
			else			. += "<h2>Vote: [capitalize(mode)]</h2>"
			. += "Time Left: [time_remaining] s<hr>"
			. += "<table width = '100%'><tr><td align = 'center'><b>Choices</b></td><td align = 'center'><b>Votes</b></td>"
			if(capitalize(mode) == "Gamemode") .+= "<td align = 'center'><b>Minimum Players</b></td></b></tr>"

			for(var/i = 1, i <= choices.len, i++)
				var/votes = choices[choices[i]]
				if(!votes)	votes = 0
				. += "<tr>"
				if(current_votes[C.ckey] == i)
					. += "<td><b><a href='?src=\ref[src];vote=[i]'>[choices[i]]</a></b></td><td align = 'center'>[votes]</td>"
				else
					. += "<td><a href='?src=\ref[src];vote=[i]'>[choices[i]]</a></b></td><td align = 'center'>[votes]</td>"

				if (additional_text.len >= i)
					. += additional_text[i]
				. += "</tr>"

			. += "</table><hr>"
			if(admin)
				. += "(<a href='?src=\ref[src];vote=cancel'>Cancel Vote</a>) "
		else
			. += "<h2>Start a vote:</h2><hr><ul><li>"
			//restart
			if(trialmin)
				. += "<a href='?src=\ref[src];vote=restart'>Restart</a>"
			else
				. += "<font color='grey'>Restart (Disallowed)</font>"
			. += "</li><li>"
			if(trialmin)
				. += "\t(<a href='?src=\ref[src];vote=toggle_restart'>[config.allow_vote_restart?"Allowed":"Disallowed"]</a>)"
			. += "</li><li>"
			//gamemode
			if(trialmin || config.allow_vote_mode)
				. += "<a href='?src=\ref[src];vote=gamemode'>GameMode</a>"
			else
				. += "<font color='grey'>GameMode (Disallowed)</font>"
			if(trialmin)
				. += "\t(<a href='?src=\ref[src];vote=toggle_gamemode'>[config.allow_vote_mode?"Allowed":"Disallowed"]</a>)"

			. += "</li>"
			//custom
			if(trialmin)
				. += "<li><a href='?src=\ref[src];vote=custom'>Custom</a></li>"
			. += "</ul><hr>"
		. += "<a href='?src=\ref[src];vote=close' style='position:absolute;right:50px'>Close</a></body></html>"
		return .


	Topic(href,href_list[],hsrc)
		if(!usr || !usr.client)	return	//not necessary but meh...just in-case somebody does something stupid
		switch(href_list["vote"])
			if("close")
				voting -= usr.client
				usr << browse(null, "window=vote")
				return
			if("cancel")
				if(usr.client.holder)
					reset()
			if("toggle_restart")
				if(usr.client.holder)
					config.allow_vote_restart = !config.allow_vote_restart
			if("toggle_gamemode")
				if(usr.client.holder)
					config.allow_vote_mode = !config.allow_vote_mode
			if("restart")
				if(config.allow_vote_restart || usr.client.holder)
					initiate_vote("restart",usr.key)
			if("gamemode")
				if(config.allow_vote_mode || usr.client.holder)
					initiate_vote("gamemode",usr.key)
			if("custom")
				if(usr.client.holder)
					initiate_vote("custom",usr.key)
			else
				submit_vote(usr.ckey, round(text2num(href_list["vote"])))
		usr.vote()

/mob/verb/vote()
	set category = "OOC"
	set name = "Vote"

	if(vote)
		src << browse(vote.interface(client),"window=vote;can_close=0")



var/MapDaemon_UID = -1 //-1 by default so we know when to set it
var/force_mapdaemon_vote = 0

//Basically, this completely ignores the voting datum etc in favor of editing a simple a simple list, player_votes
//Upon request by MapDaemon, world/Topic() will it into JSON and send it away, so we do 0 handling in DM
/client/verb/mapVote()
	set category = "OOC"
	set name = "Map Vote"

	if(!ticker.mode || !ticker.mode.round_finished)
		to_chat(src, "<span class='notice'>Please wait until the round ends.</span>")
		return

	var/list/L = list()
	L += "Don't care"
	L += NEXT_MAP_CANDIDATES.Copy()
	var/selection = input("Vote for the next map to play on", "Vote:", "Don't care") as null|anything in L

	if(!selection || !src) return

	if(selection == "Don't care")
		to_chat(src, "<span class='notice'>You have not voted.</span>")
		return

	to_chat(src, "<span class='notice'>You have voted for [selection].</span>")

	player_votes[src.ckey] = selection

/client/proc/forceMDMapVote()
	set name = "Map Vote - Force Initiate"
	set category = "Server"

	force_mapdaemon_vote = !force_mapdaemon_vote
	to_chat(src, "<span class='notice'>The server will [force_mapdaemon_vote ? "now" : "no longer"] tell Mapdaemon to start a vote the next time possible.</span>")

	message_admins("[src] is attempting to force a MapDaemon vote.")
	log_admin("[src] is attempting to force a MapDaemon vote.")

//Uses an invalid ckey to rig the votes
//Special case for }}} handled in World/Topic()
//Set up so admins can fight over what the map will be, hurray
/client/proc/forceNextMap()
	set name = "Map Vote - Force"
	set category = "Server"

	if(alert("Are you sure you want to force the next map?",, "Yes", "No") == "No") return

	var/selection = input("Vote for the next map to play on", "Vote:", "LV-624") as null|anything in NEXT_MAP_CANDIDATES

	if(!selection || !src) return

	to_chat(src, "<span class='notice'>You have forced the next map to be [selection]</span>")

	log_admin("[src] just forced the next map to be [selection].")
	message_admins("[src] just forced the next map to be [selection].")

	player_votes["}}}"] = selection //}}} is an invalid ckey so we won't be in risk of someone using this cheekily


var/enable_map_vote = 1
/client/proc/cancelMapVote()
	set name = "Map Vote - Toggle"
	set category = "Server"

	if(alert("Are you sure you want to turn the map vote [!enable_map_vote ? "on" : "off"]?",, "Yes", "No") == "No") return

	enable_map_vote = !enable_map_vote

	to_chat(world, "<span class='notice'>[src] has toggled the map vote [enable_map_vote ? "on" : "off"]</span>")
	to_chat(src, "<span class='notice'>You have toggled the map vote [enable_map_vote ? "on" : "off"]</span>")

	log_admin("[src] just toggled the map vote [enable_map_vote ? "on" : "off"].")
	message_admins("[src] just toggled the map vote [enable_map_vote ? "on" : "off"].")

/client/proc/showVotableMaps()
	set name = "Map Vote - List Maps"
	set category = "Server"

	to_chat(src, "Next map candidates:")
	var/i
	for(i in NEXT_MAP_CANDIDATES)
		to_chat(src, i)

/client/proc/editVotableMaps()
	set name = "Map Vote - Edit Maps"
	set category = "Server"

	if(alert("Are you sure you want to edit the map voting candidates?",, "Yes", "No") == "No") return

	switch(alert("Do you want to add or remove a map?",, "Add", "Remove", "Cancel"))
		if("Cancel")
			return
		if("Add")
			var/selection = ""
			switch(alert("Do you want to add one of the default map possibilities?",, "Yes", "No"))
				if("Yes")
					selection = input("Pick a default map.") as null|anything in DEFAULT_NEXT_MAP_CANDIDATES
				if("No")
					if(alert("Warning! This is a very dangerous option. If there is a typo in the map name and your choice wins, MapDaemon will crash. Please make sure you enter the exact name of the map. Are you sure you want to continue?", "WARNING", "Yes", "No") == "No") return
					selection = input("Enter a map at your own risk.")

			if(!selection || !src) return
			if(NEXT_MAP_CANDIDATES.Find(selection))
				alert("That option was already available.")
				return
			NEXT_MAP_CANDIDATES.Add(selection)
			message_admins("[src] just added [selection] to the map pool.")
			log_admin("[src] just added [selection] to the map pool.")
		if("Remove")
			var/selection = input("Pick a map to remove from the pool") as null|anything in NEXT_MAP_CANDIDATES
			if(!selection || !src) return
			NEXT_MAP_CANDIDATES.Remove(selection)
			message_admins("[src] just removed [selection] from the map pool.")
			log_admin("[src] just removed [selection] from the map pool.")

var/kill_map_daemon = 0
/client/proc/killMapDaemon()
	set name = "Map Vote - Kill MapDaemon"
	set category = "Server"

	if(alert("Are you sure you want to kill MapDaemon?",, "Yes", "No") == "No") return

	kill_map_daemon = 1

	alert("MapDaemon will be killed on next round-end check.")
	message_admins("[src] just killed MapDaemon. It may be restarted with \"Map Vote - Revive MapDaemon\".")
	log_admin("[src] just killed MapDaemon. It may be restarted with \"Map Vote - Revive MapDaemon\".")

//Need to return 1 so that the thing calling hooks wont think that this failed
/hook/roundstart/proc/launchMapDaemon()

	run_mapdaemon_batch()

	return 1

/proc/run_mapdaemon_batch()

	set waitfor = 0

	if(world.system_type != MS_WINDOWS) return 0 //Don't know if it'll work for non-Windows, so let's just abort

	shell("run_mapdaemon.bat")


/client/proc/reviveMapDaemon()
	set name = "Map Vote - Revive MapDaemon"
	set category = "Server"

	kill_map_daemon = 0

	message_admins("[src] is attempting to restart MapDaemon.")
	log_admin("[src] is attempting to restart MapDaemon.")

	run_mapdaemon_batch()


//############################################ HUB DAEMON HERE #####################################


/proc/run_hub_daemon_py()
	set waitfor = 0
	if(world.system_type != MS_WINDOWS)
		shell("python3 pymapdaemon.py")
	else
		shell("python.exe pymapdaemon.py --bind 127.0.0.1") //DO NOT FORGET TO CHANGE IT TO PROPER NAME!!!!11


/hook/roundend/proc/initiate_roundend_vote()
	run_hub_daemon_py()
	initiate_map_voting()
	return 1

/proc/initiate_map_voting()
	if(!ticker) return
	sleep(20)

	send_map_info("current_map:" + map_tag)

	var/text = ""
	text += "<hr><br>"
	text += "<span class='centerbold'>"
	text += "<font color='#00CC00'><b>You have 30 seconds to vote for the next map! Use the \"Map Vote\" verb in the OOC tab or click <a href='?src=\ref[src];vote_for_map=1'>here</a> to select an option.</b></font>"
	text += "</span>"
	text += "<hr><br>"

	to_chat(world, text)
	world << 'sound/voice/start_your_voting.ogg'

	ticker.delay_end = 1
	log_admin("Round delayed to process votes.")
	message_admins("Round delayed to process votes.", 1)

	sleep(310) //wait for 30 sec

	// procces votes
	if(!ticker) return "ERROR"


	var/list/L = list()

	var/i
	for(i in NEXT_MAP_CANDIDATES)
		L[i] = 0 //Initialize it

	var/forced = 0
	var/force_result = ""
	i = null //Sanitize for safety
	var/j
	for(i in player_votes)
		j = player_votes[i]
		if(i == "}}}") //Special invalid ckey for forcing the next map
			forced = 1
			force_result = j
			continue
		L[j] = L[j] + 1 //Just number of votes indexed by map name

	i = null
	var/most_votes = -1
	var/next_map = ""
	for(i in L)
		if(L[i] > most_votes)
			most_votes = L[i]
			next_map = i

	if(!enable_map_vote && ticker && ticker.mode)
		next_map = ticker.mode.name
	else if(enable_map_vote && forced)
		next_map = force_result

	text = ""
	text += "<font color='#00CC00'>"

	var/log_text = ""
	log_text += "\[[time2text(world.realtime, "DD Month YYYY")]\] Winner: [next_map] ("

	text += "The voting results were:<br>"
	for(var/name in L)
		text += "[name] - [L[name]]<br>"
		log_text += "[name] - [L[name]],"

	log_text += ")\n"

	if(forced) text += "<b>An admin has forced the next map.</b><br>"
	else
		text2file(log_text, "data/map_votes.txt")

	text += "<b>The next map will be on [forced ? force_result : next_map].</b>"

	text += "</font>"

	to_chat(world, text)

	send_map_info("next_map:" + next_map) //############################################# THIS #################################


	// votes processed, moving on
	ticker.delay_end = 0
	message_admins("Votes processed", 1)

	//So admins have a chance to make EORG bans and do whatever
	message_staff("NOTICE: Delay round within 30 seconds in order to prevent auto-restart!", 1)

	return "success"


//############################################ HUB DAEMON HERE #######################################