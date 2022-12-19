import lupa

import webbrowser
import os

def open_url_in_browser(path: str):
  webbrowser.open(path)

if __name__ == '__main__':
  landing_page_url = 'file:///C:/Users/T9147282/Documents/Talpiot/SOS-WIFI/landing_page.html'
  open_url_in_browser(landing_page_url)