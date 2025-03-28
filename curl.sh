#!/bin/bash

# Function to display all running Docker containers in a human-readable table
list_docker_containers() {
    echo "Listing all running Docker containers:"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"
}

# Function to calculate the space taken up by subfolders in a given folder
calculate_folder_space() {
    read -p "Enter the folder path: " folder
    if [ -d "$folder" ]; then
        echo "Space taken up by subfolders in $folder:"
        du -h --max-depth=1 "$folder" | sort -h
    else
        echo "Invalid folder path. Please try again."
    fi
}

# Function to update Ubuntu
update_ubuntu() {
    echo "Updating Ubuntu..."
    sudo apt update && sudo apt upgrade -y
    echo "Ubuntu update completed."
}

# Function to list used ports and what is binding them
list_used_ports() {
    echo "Listing used ports and their bindings:"
    sudo netstat -tuln | awk 'NR==2 || /^tcp|^udp/ {print $1, $4, $6}'
}

# Main menu
while true; do
    echo "Select an option:"
    echo "1) List all running Docker containers"
    echo "2) Calculate space taken up by subfolders in a folder"
    echo "3) Update Ubuntu"
    echo "4) List used ports and their bindings"
    echo "5) Exit"
    read -p "Enter your choice: " choice

    case $choice in
        1)
            list_docker_containers
            ;;
        2)
            calculate_folder_space
            ;;
        3)
            update_ubuntu
            ;;
        4)
            list_used_ports
            ;;
        5)
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid choice. Please try again."
            ;;
    esac

    echo ""
done
