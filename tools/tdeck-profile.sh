# Make the writable T-Deck tools available by command name.
case ":$PATH:" in
	*:/home/bin:*) ;;
	*) PATH="/home/bin:$PATH" ;;
esac
export PATH
