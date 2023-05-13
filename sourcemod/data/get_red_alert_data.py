import json
import requests
import re

# Get page that contains the data.
areas_json = requests.get('https://www.oref.org.il/12481-he/Pakar.aspx', headers={'Referer': 'https://www.oref.org.il/'})

# Get all the areas.
matches = re.findall(r'{ code: \"(\d+)\", area: \"([א-ת ]+)\" }', areas_json.text, flags=re.MULTILINE)

# Sort the areas.
matches.sort(key=lambda x: int(x[0]))

# Create a dictionary with the areas.
areas = dict(map(lambda x: (x[1], int(x[0])), matches))

# Write the areas to a file.
with open('generated_areas.json', 'wb') as output:
    output.write(json.dumps(areas, ensure_ascii=False).encode('utf-8'))


# Get JSON with the districts.
districts_json = requests.get('https://www.oref.org.il/Shared/Ajax/GetDistricts.aspx?lang=he').json()

# Save only the data we need.
districts_out = {}
for district in districts_json:
    districts_out[district['label']] = int(district['areaid'])

# Write the districts to a file.
with open('generated_districts.json', 'wb') as districts:
    districts.write(json.dumps(districts_out, ensure_ascii=False).encode('utf-8'))