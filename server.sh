#!/bin/bash
address=$(ifconfig | grep 'inet ' | grep -v "127.0.0.1" | awk '{print $2}')
nc -l 1234 & sleep 0.5 
port=$(ss -ltn | grep -o "1234" | head -n 1)
echo "Server is running at $address, port=$port" 
while true; do
    message=$(nc -l 1234)
    if [ "$message" = "assignment" ]; then
      url="https://sydney.edu.au"
      json=$(curl -s $url)
      status=$?
      if [ $status -eq 0 ]; then
        echo "$json"
      fi
    elif [ "$message" = "population" ]; then
        
    fi
    elif [ "$message" = "where am I" ]; then
       
    fi
    else 
      echo "Invalid message received: $message"
    fi
    done 
    

