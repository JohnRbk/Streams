main:
	swiftc -import-objc-header Streams-Bridging-Header.h  -L /usr/local/lib -I . -I /usr/local/include -lgeos -lgeos_c -lpq -o gen_image main.swift
